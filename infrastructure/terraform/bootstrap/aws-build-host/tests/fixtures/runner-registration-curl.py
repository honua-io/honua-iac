#!/usr/bin/python3
import json, os, pathlib, sys
args = sys.argv[1:]
url = args[-1]
root = pathlib.Path(os.environ['TEST_ROOT'])
with (root / 'requests').open('a') as log: log.write(url + '\n')
if '-X' in args and args[args.index('-X') + 1] == 'DELETE':
    print(os.environ.get('DELETE_STATUS', '204'), end='')
    sys.exit(0)
if url.endswith('/latest/api/token'):
    print('token'); sys.exit(0)
if url.endswith('/latest/meta-data/instance-id'):
    print('i-abc123'); sys.exit(0)
if '/access_tokens' in url:
    if os.environ.get('QUEUE_DENIED'): sys.exit(22)
    print('{"token":"test-queue-token"}'); sys.exit(0)
if '/actions/runs?' in url:
    print(json.dumps({'total_count': int(os.environ.get('RUN_COUNT', '1')),
                      'workflow_runs': [{'id': 99}]})); sys.exit(0)
if '/actions/runs/99/jobs?' in url:
    if os.environ.get('QUEUE_FAILED'): sys.exit(22)
    page = int(url.rsplit('page=', 1)[-1])
    if os.environ.get('LATE_HEAVY') and page == 1:
        print(json.dumps({'total_count':101, 'jobs':[{'status':'completed','labels':['honua-heavy']}]*100})); sys.exit(0)
    labels = ['honua-heavy'] if os.environ.get('HEAVY_WAITING') or os.environ.get('LATE_HEAVY') else ['honua-light']
    job = {} if os.environ.get('BAD_JOB') else {'status': os.environ.get('JOB_STATUS','queued'), 'labels': labels}
    print(json.dumps({'total_count':101 if os.environ.get('LATE_HEAVY') else 1, 'jobs':[] if os.environ.get('EMPTY_JOBS') else [job]})); sys.exit(0)
if url.endswith('/generate-jitconfig'):
    (root / 'jit-request').write_text(args[args.index('-d') + 1])
    print(json.dumps({'runner': {'id': json.loads(os.environ.get('RUNNER_ID', '123'))},
                      'encoded_jit_config': 'test-jit'})); sys.exit(0)
page = root / (('heavy-page-' if '/runner-groups/43/' in url else 'page-') + url.rsplit('page=', 1)[-1])
print(page.read_text() if page.exists() else '{"runners": []}')
