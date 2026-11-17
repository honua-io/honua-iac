"""Capture immutable template inventory and AWS public authorization metadata."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import urllib.request
import zipfile

import yaml

from features import project_snapshot
from runtime import template_services

SCHEMAS = "https://schema.cloudformation.us-east-1.amazonaws.com/CloudformationSchema.zip"
SERVICES = "https://servicereference.us-east-1.amazonaws.com/v1/service-list.json"


class TemplateLoader(yaml.SafeLoader):
    pass


def intrinsic(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {tag if tag in {"Ref", "Condition"} else "Fn::" + tag: value}


TemplateLoader.add_multi_constructor("!", intrinsic)


def read_templates(checkout, commit, manifest):
    mappings, used, templates = manifest.get("nested", {}), set(), {}

    def visit(path, ancestors):
        if path in ancestors:
            raise ValueError(f"Nested template cycle: {path}")
        if path in templates:
            return
        source = subprocess.check_output(["git", "-C", str(checkout), "show", f"{commit}:{path}"])
        template = yaml.load(source, Loader=TemplateLoader)
        if "AWS::Include" in json.dumps(template):
            raise ValueError("AWS::Include requires expanded source before snapshotting")
        templates[path] = {"path": path, "sha256": hashlib.sha256(source).hexdigest(),
                           "resources": template.get("Resources", {})}
        for name, resource in template.get("Resources", {}).items():
            if resource["Type"] == "AWS::CloudFormation::Stack":
                key = f"{path}#{name}"
                if key not in mappings:
                    raise ValueError(f"Nested template mapping required: {key}")
                used.add(key)
                visit(mappings[key], ancestors | {path})

    visit(manifest["root"], set())
    if used != mappings.keys():
        raise ValueError(f"Unused nested template mappings: {sorted(mappings.keys() - used)}")
    return list(templates.values())


def download(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def registry_schemas(archive, types):
    found = {}
    with zipfile.ZipFile(io.BytesIO(archive)) as schemas:
        for name in schemas.namelist():
            schema = json.loads(schemas.read(name))
            if schema["typeName"] in types:
                found[schema["typeName"]] = {
                    "handlers": {key: handler.get("permissions", [])
                                 for key, handler in schema.get("handlers", {}).items()},
                    "tagging": schema.get("tagging", {})}
    missing = types - found.keys()
    if missing:
        raise ValueError(f"Registry schemas missing: {sorted(missing)}")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("commit")
    parser.add_argument("output", type=Path)
    parser.add_argument("--nested-template", action="append", default=[], metavar="PARENT#LOGICAL=PATH")
    args = parser.parse_args()
    commit = subprocess.check_output(["git", "-C", str(args.checkout), "rev-parse", args.commit], text=True).strip()
    manifest = {"root": "aws/cloudformation/container-product/deploy.yaml",
                "nested": dict(mapping.split("=", 1) for mapping in args.nested_template)}
    templates = read_templates(args.checkout, commit, manifest)
    types = {r["Type"] for t in templates for r in t["resources"].values() if r["Type"].startswith("AWS::")}
    archive = download(SCHEMAS)
    schemas = registry_schemas(archive, types)
    actions = {a.lower() for s in schemas.values() for p in [*s["handlers"].values(), s.get("tagging", {}).get("permissions", [])] for a in p}
    index = {s["service"]: s["url"] for s in json.loads(download(SERVICES))}
    services = {a.split(":")[0] for a in actions} | template_services(templates)
    authorization = {s: json.loads(download(index[s])) for s in sorted(services) if s in index}
    result = {"commit": commit, "schemaSource": SCHEMAS, "schemaSha256": hashlib.sha256(archive).hexdigest(),
              "authorizationSource": SERVICES, "templates": templates, "schemas": schemas,
              "authorization": authorization}
    args.output.write_text(json.dumps(project_snapshot(result), indent=2) + "\n")


if __name__ == "__main__":
    main()
