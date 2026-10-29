import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('review', Path(__file__).with_name('openai-api-review.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def pr(sha='abc', **updates):
    result = {'state':'open', 'draft':False, 'base':{'ref':'main','repo':{'full_name':'owner/repo'}},
              'head':{'sha':sha,'repo':{'full_name':'owner/repo'}}, 'author_association':'OWNER'}
    result.update(updates)
    return result


class ReviewTests(unittest.TestCase):
    def test_untrusted_automatic_pr_rejected(self):
        self.assertFalse(r.eligible(pr(author_association='CONTRIBUTOR')))
        self.assertFalse(r.eligible(pr(head={'sha':'abc','repo':{'full_name':'fork/repo'}})))
        self.assertFalse(r.eligible(pr(head={'sha':'abc','repo':None})))
        self.assertTrue(r.eligible(pr(head={'sha':'abc','repo':None}), manual=True))
        self.assertFalse(r.eligible(pr(draft=True), manual=True))

    def test_sensitive_binary_and_oversized_patches_omitted(self):
        files = [{'filename':'.env','patch':'+TOKEN=secret'},
                 {'filename':'x.py','patch':'+key="sk-'+'a'*40+'"'},
                 {'filename':'x.png'}, {'filename':'big.txt','patch':'a'*(r.MAX_PATCH_CHARS+1)},
                 {'filename':'ok.py','patch':'+return 0'}]
        selected, omitted = r.safe_patch(files)
        self.assertEqual([x['path'] for x in selected], ['ok.py'])
        self.assertEqual(len(omitted), 4)

    def test_duplicate_does_not_call_openai(self):
        with patch.dict(os.environ, {'PR_NUMBER':'1'}), patch.object(r, 'github', return_value=pr()), \
             patch.object(r, 'pages', return_value=[{'body':r.MARKER+'abc -->','user':{'login':'github-actions[bot]'}}]), \
             patch.object(r, 'request') as api:
            r.main()
            api.assert_not_called()

    def test_incomplete_response_not_clean_review(self):
        with self.assertRaises(RuntimeError):
            r.parse_response({'status':'incomplete','output':[]})

    def test_stale_result_not_posted(self):
        response = {'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'{"findings":[]}'}]}]}
        with patch.dict(os.environ, {'PR_NUMBER':'1','OPENAI_REVIEW_API_KEY':'test'}), \
             patch.object(r,'github',side_effect=[pr('abc'),pr('def')]) as gh, \
             patch.object(r,'pages',side_effect=[[],[{'filename':'x.py','patch':'+return 1'}]]), \
             patch.object(r,'request',return_value=response):
            r.main()
            self.assertEqual(gh.call_count,2)

    def test_model_output_cannot_inject_image_or_mention(self):
        body=r.render({'findings':[{'priority':'P1','path':'x.py','detail':'![x](https://bad) @all <img>'}]},
                      [{'path':'x.py'}],[],'abc',{})
        self.assertNotIn('![x]',body)
        self.assertNotIn('@all',body)
        self.assertNotIn('<img>',body)
        with self.assertRaises(RuntimeError):
            r.render({'findings':[{'priority':'P1','path':'other','detail':'bug'}]},[{'path':'x.py'}],[],'abc',{})


if __name__=='__main__':
    unittest.main()
