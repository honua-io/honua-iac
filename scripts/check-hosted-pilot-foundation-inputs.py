#!/usr/bin/env python3
"""Validate only the reviewed candidate-independent, nonsecret pilot inputs."""
import argparse
import hashlib
import importlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RELATIVE = 'certification/hosted-pilot/bootstrap/deployments/foss4g-images.tfvars.json'
RELEASE_ANCESTOR = 'ab250e990d7748f4abf76711eb18836ef371cec1'

def require(value, reason):
    if not value: raise ValueError(reason)

def check(root=ROOT, *, release_source=None):
    path=Path(root)/RELATIVE
    require(path.is_file() and not path.is_symlink(),'reviewed nonsecret pilot configuration missing')
    raw=path.read_bytes(); cfg=json.loads(raw)
    fields={'account_id','region','name_prefix','owner','expires_at','oidc_provider_arn','runtime_secret_arns',
        'runtime_kms_key_arns','enable_agent_controller','controller_model_resource_arns','provision_policy_document',
        'image_preparation_funding','budget_ledger'}
    require(set(cfg)==fields and cfg['account_id']=='585192672263' and cfg['region']=='us-east-1' and
        cfg['name_prefix']=='honua-pilot-foss4g' and cfg['owner']=='Mike McDougall','reviewed pilot identity differs')
    require(cfg['oidc_provider_arn']=='arn:aws:iam::585192672263:oidc-provider/token.actions.githubusercontent.com' and
        cfg['runtime_secret_arns']==['arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/operation-key-ring-zDn618',
            'arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/audit-chain-key-RLtpME'] and
        cfg['runtime_kms_key_arns']==[],'existing independent secret/OIDC references differ')
    require(cfg['image_preparation_funding'] is True and cfg['enable_agent_controller'] is True and
        cfg['controller_model_resource_arns']==[],'candidate-independent stage cannot enable inference')
    policy=json.loads(cfg['provision_policy_document'])
    expected={'Version':'2012-10-17','Statement':[{'Sid':'CandidateIndependentImagePreparationOnly','Effect':'Allow',
        'Action':['ecr:DescribeRepositories','ecr:GetLifecyclePolicy'],
        'Resource':['arn:aws:ecr:us-east-1:585192672263:repository/honua-pilot-foss4g-trusted-controller',
            'arn:aws:ecr:us-east-1:585192672263:repository/honua-pilot-foss4g-worker']}]}
    require(policy==expected,'initial provisioning attachment must contain only reviewed registry metadata reads')
    ledger=cfg['budget_ledger']
    require(set(ledger)=={'schema','expires_at','source_sha','config_sha256','total_budget_usd','cleanup_reserve_usd',
        'spent_usd','reserved_usd','deployment_reservation_usd','active_paid_attempts','reservation_id'} and
        ledger['schema']=='honua.hosted-pilot-budget/v1' and ledger['source_sha'] is None and ledger['config_sha256'] is None and
        ledger['total_budget_usd']==2000 and ledger['cleanup_reserve_usd']==200 and ledger['reserved_usd']==294 and
        ledger['spent_usd']==0 and ledger['deployment_reservation_usd']==5 and ledger['active_paid_attempts']==0 and
        ledger['reservation_id']=='foundation-image-preparation-001','original nonzero funding or stable publication identity differs')
    if release_source is not None:
        release_source=Path(release_source).resolve()
        def git(*args):return subprocess.check_output(['git','-C',str(release_source),*args])
        source=git('rev-parse','HEAD').decode().strip()
        subprocess.run(['git','-C',str(release_source),'merge-base','--is-ancestor',RELEASE_ANCESTOR,source],check=True)
        require(git('show',source+':'+RELATIVE)==raw,'IaC configuration differs from exact reviewed release bytes')
        sys.path[:0]=[str(release_source/'tools/hosted_pilot'),str(release_source/'tools')]
        bootstrap=importlib.import_module('bootstrap')
        require(callable(getattr(bootstrap,'resolve_image_funding',None)),'selected release source lacks the reviewed funding compiler')
        compiled=bootstrap.resolve_image_funding(cfg,release_source,source)
        funding=release_source/'certification/hosted-pilot/deployments/foss4g-image-preparation.tfvars.json'
        require('image_preparation_funding' not in compiled and compiled['budget_ledger']['source_sha']==source and
            compiled['budget_ledger']['config_sha256']==hashlib.sha256(funding.read_bytes()).hexdigest(),
            'actual release source did not compile exact private funding identities')
    return hashlib.sha256(raw).hexdigest()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-source',type=Path)
    args=parser.parse_args()
    print('Reviewed nonsecret foundation input SHA256: '+check(release_source=args.release_source))
