"""Inventory inline boto3 calls without publishing handler code or inputs.

This is a conservative function-wide inventory, not control-flow analysis or
execution-role authorization. Dynamic SDK clients require manual review.
"""
import ast


def client_service(node):
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name) and node.func.value.id == "boto3"
            and node.func.attr == "client" and node.args
            and isinstance(node.args[0], ast.Constant)):
        return node.args[0].value
    return None


def client_bindings(tree):
    bindings = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and (service := client_service(node.value)):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    bindings.setdefault(target.id, set()).add(service)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            arguments = node.args.posonlyargs + node.args.args
            defaults = zip(arguments[-len(node.args.defaults):], node.args.defaults)
            for argument, value in defaults:
                if service := client_service(value):
                    bindings.setdefault(argument.arg, set()).add(service)
    for name, service in helper_clients(tree):
        bindings.setdefault(name, set()).add(service)
    return bindings


def helper_clients(tree):
    functions = {node.name: node for node in ast.walk(tree)
                 if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
            continue
        function = functions.get(node.func.id)
        if function is None:
            continue
        parameters = function.args.posonlyargs + function.args.args
        values = [(parameter.arg, value) for parameter, value in zip(parameters, node.args)]
        values.extend((keyword.arg, keyword.value) for keyword in node.keywords if keyword.arg)
        for name, value in values:
            if service := client_service(value):
                yield name, service


def inline_actions(code, authorization):
    tree = ast.parse(code)
    bindings, actions = client_bindings(tree), set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        target = node.func.value
        services = ({client_service(target)} if client_service(target) else
                    bindings.get(target.id, set()) if isinstance(target, ast.Name) else set())
        if not services:
            continue
        method = node.func.attr.replace("_", "").lower()
        matches = {f'{service}:{action["Name"]}' for service in services
                   for action in authorization.get(service, {}).get("Actions", [])
                   if action["Name"].lower() == method}
        actions.update(matches or {"unknown:" + node.func.attr})
    return sorted(actions)


def custom_actions(resource, resources, authorization):
    token = resource.get("Properties", {}).get("ServiceToken", {})
    reference = token.get("Fn::GetAtt", []) if isinstance(token, dict) else []
    name = reference[0] if isinstance(reference, list) and len(reference) == 2 else None
    function = resources.get(name, {})
    code = function.get("Properties", {}).get("Code", {}).get("ZipFile")
    return inline_actions(code, authorization) if isinstance(code, str) else None


def template_services(templates):
    services = set()
    for template in templates:
        for resource in template["resources"].values():
            code = resource.get("Properties", {}).get("Code", {}).get("ZipFile")
            if isinstance(code, str) and resource["Type"] == "AWS::Lambda::Function":
                services.update(service for node in ast.walk(ast.parse(code))
                                if (service := client_service(node)))
    return services
