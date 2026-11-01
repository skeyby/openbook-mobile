#!/usr/bin/env python3
"""Reread the upstream contract; never silently accept a changed API."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--spec', type=Path, default=ROOT.parent / 'openbook/docs/api/openapi.json')
parser.add_argument('--record', action='store_true', help='Record the reviewed contract and refresh official example fixtures')
args = parser.parse_args()
try:
    raw = args.spec.read_bytes()
    spec = json.loads(raw)
except (OSError, ValueError) as error:
    sys.exit(f'Impossibile leggere la specifica {args.spec}: {error}')
operations = sorted(f'{method.upper()} {path}' for path, value in spec['paths'].items()
                    for method in value if method in {'get', 'post', 'put', 'patch', 'delete'})
record = {'sha256': hashlib.sha256(raw).hexdigest(), 'version': spec['info']['version'], 'operations': operations}
baseline = ROOT / 'docs/api-baseline.json'
print(f"Specifica: {args.spec}\nVersione: {record['version']}\nSHA-256: {record['sha256']}")
print('\n'.join(operations))
if args.record:
    baseline.write_text(json.dumps(record, indent=2) + '\n')
    examples = spec['components']['schemas']['Person']['examples']
    (ROOT / 'Tests/OpenBookCoreTests/Fixtures/person.json').write_text(json.dumps(examples[0], indent=2) + '\n')
    post_examples = spec['paths']['/posts']['get']['responses']['200']['content']['application/json']['examples']
    for engine in ('world', 'timeline'):
        (ROOT / f'Tests/OpenBookCoreTests/Fixtures/posts-{engine}.json').write_text(json.dumps(post_examples[engine]['value'], indent=2) + '\n')
    creation = spec['paths']['/posts']['post']['responses']['201']['content']['application/json']['example']
    (ROOT / 'Tests/OpenBookCoreTests/Fixtures/created-post.json').write_text(json.dumps(creation, indent=2) + '\n')
    profile_posts = spec['paths']['/persons/{personId}/posts']['get']['responses']['200']['content']['application/json']['example']
    (ROOT / 'Tests/OpenBookCoreTests/Fixtures/person-posts.json').write_text(json.dumps(profile_posts, indent=2) + '\n')
    incoming = spec['paths']['/me/follow-requests']['get']['responses']['200']['content']['application/json']['examples']['empty']['value']
    (ROOT / 'Tests/OpenBookCoreTests/Fixtures/follow-requests-empty.json').write_text(json.dumps(incoming, indent=2) + '\n')
    acceptance = spec['paths']['/me/follow-requests/{personId}']['patch']['requestBody']['content']['application/json']['example']
    (ROOT / 'Tests/OpenBookCoreTests/Fixtures/accept-follow-request.json').write_text(json.dumps(acceptance, indent=2) + '\n')
    follows = spec['paths']['/persons/{personId}/follow']['get']['responses']['200']['content']['application/json']['examples']
    for name, example in follows.items():
        (ROOT / f'Tests/OpenBookCoreTests/Fixtures/follow-{name}.json').write_text(json.dumps(example['value'], indent=2) + '\n')
    my_posts = spec['paths']['/me/posts']['get']['responses']['200']['content']['application/json']['examples']['owned']['value']
    (ROOT / 'Tests/OpenBookCoreTests/Fixtures/my-posts.json').write_text(json.dumps(my_posts, indent=2) + '\n')
    instance_examples = spec['paths']['/instance']['get']['responses']['200']['content']['application/json']['examples']
    for name, example in instance_examples.items():
        (ROOT / f'Tests/OpenBookCoreTests/Fixtures/instance-{name}.json').write_text(json.dumps(example['value'], indent=2) + '\n')
    print('Baseline ed esempi ufficiali aggiornati. Eseguire i test e rivedere il diff.')
elif not baseline.exists() or json.loads(baseline.read_text()) != record:
    sys.exit('La specifica è cambiata: rileggerla e adattare codice/test prima di usare --record.')
else:
    print('La specifica coincide con la baseline revisionata.')
