#!/usr/bin/env python3
"""The installed foundation workflow must not join phases or deadlock review."""
import copy
import json
from pathlib import Path
import unittest
import yaml

ROOT=Path(__file__).resolve().parents[1]
def require(value,message):
    if not value:raise ValueError(message)

def validate(document):
    dispatch=document.get('on',document.get(True))['workflow_dispatch']['inputs']
    require(dispatch['mode']['options']==['plan','apply'] and dispatch['phase']['options']==['custody-only','remote-backed-foundation'],'one explicit phase and no combined deploy mode required')
    require(document['permissions']=={'contents':'read','actions':'read'},'workflow permissions must remain read-only')
    jobs=document['jobs']
    require(set(jobs)=={'approval-policy','bootstrap','review-ready','phase-approval','phase-watchdog'},'unreviewed foundation job')
    for name,expected in [('bootstrap','approval-policy'),('review-ready','approval-policy'),('phase-watchdog','approval-policy'),('phase-approval',['approval-policy','review-ready'])]:
        require(jobs[name]['needs']==expected,'approval cannot depend on completion of the retained-plan executor')
    require(jobs['bootstrap']['environment']=='terraform-ephemeral' and jobs['phase-approval']['environment']=='terraform-live-approval','real human environment must protect the separate approval job')
    require(jobs['phase-watchdog']['permissions']=={'contents':'read','actions':'write'} and all('permissions' not in job for name,job in jobs.items() if name!='phase-watchdog'),'only watchdog receives cancellation authority')
    for name,job in jobs.items():
        if name!='bootstrap':
            require(not any('configure-aws-credentials@' in step.get('uses','') for step in job['steps']) and not any(key.startswith('AWS_') for key in job.get('env',{})) and 'secrets' not in json.dumps(job).lower(),'only original executor may receive AWS credentials')
        for step in job['steps']:
            if 'upload-artifact@' in step.get('uses',''):
                require(step['with']['path'].split('/')[-1] in {'review.json','approved.json','bindings.json','custody-recovery.json','custody-applied.json','apply-admitted.json'},'only reviewed metadata filenames may leave the executor')
    steps=jobs['bootstrap']['steps'];names=[step.get('name','') for step in steps]
    prepare=names.index('Prepare exactly one source-reviewed phase without applying')
    publish=names.index('Publish value-free review before waiting for native approval')
    wait=names.index('Wait for original exact-plan approval from the separate protected job')
    apply=names.index('Apply only the exact reviewed phase and stop')
    require(prepare<publish<wait<apply,'exact review must be available before protection and original binary apply')
    require(steps[prepare]['env']['MODE']=="${{ inputs.mode == 'apply' && 'prepare' || 'plan' }}" and 'bootstrap.py apply --phase "$PHASE"' in steps[apply]['run'],'caller input cannot choose a hidden combined operation')
    require('bootstrap_phase.py watchdog --phase "$PHASE"' in jobs['phase-watchdog']['steps'][-1]['run'],'fixed source-bound own-run watchdog required')
    return True

class PhaseWorkflow(unittest.TestCase):
    def setUp(self):self.document=yaml.safe_load((ROOT/'.github/workflows/hosted-pilot-bootstrap.yml').read_text())
    def test_installed_phase_workflow_passes_without_aws(self):self.assertTrue(validate(self.document))
    def test_approval_wait_cycle_and_joined_deploy_are_refused(self):
        bad=copy.deepcopy(self.document);bad['jobs']['review-ready']['needs']='bootstrap'
        with self.assertRaises(ValueError):validate(bad)
        bad=copy.deepcopy(self.document);bad.get('on',bad.get(True))['workflow_dispatch']['inputs']['mode']['options'].append('deploy')
        with self.assertRaises(ValueError):validate(bad)
    def test_broad_actions_authority_and_approval_job_aws_credentials_refuse(self):
        bad=copy.deepcopy(self.document);bad['permissions']['actions']='write'
        with self.assertRaises(ValueError):validate(bad)
        bad=copy.deepcopy(self.document);bad['jobs']['phase-approval']['env']['AWS_ACCESS_KEY_ID']='forbidden-test-placeholder'
        with self.assertRaises(ValueError):validate(bad)
        bad=copy.deepcopy(self.document);bad['jobs']['phase-watchdog']['steps'].append({'run':'true','env':{'UNREVIEWED':'${{ secrets.AWS_SECRET_ACCESS_KEY }}'}})
        with self.assertRaises(ValueError):validate(bad)
    def test_public_binary_upload_or_wrong_protection_refuses(self):
        bad=copy.deepcopy(self.document);upload=next(step for step in bad['jobs']['bootstrap']['steps'] if 'upload-artifact@' in step.get('uses',''));upload['with']['path']='private/custody.tfplan'
        with self.assertRaises(ValueError):validate(bad)
        bad=copy.deepcopy(self.document);bad['jobs']['phase-approval']['environment']='terraform-ephemeral'
        with self.assertRaises(ValueError):validate(bad)

if __name__=='__main__':unittest.main()
