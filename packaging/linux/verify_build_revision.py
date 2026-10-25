"""Bind an artifact's checkout to its authenticated Actions run."""


def verify_revision(built_sha, parents, metadata):
    source_sha = metadata['sourceSHA']
    if built_sha == source_sha:
        return
    expected = metadata.get('pullRequestParents', [])
    if metadata.get('event') == 'pull_request' and len(parents) == 2 and any(
        parents == [pair['baseSHA'], source_sha] for pair in expected
    ):
        return
    raise ValueError('Fresh build required: artifact checkout is not the requested source or its verified PR merge')
