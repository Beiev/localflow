#!/usr/bin/env python3
"""Same synthetic inputs and app prompts, one model per isolated process. No archive reads."""
import argparse
import gc
import importlib.metadata
import json
import re
import time
from pathlib import Path
import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

parser = argparse.ArgumentParser()
parser.add_argument('model_path', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--cases', type=int, default=10)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
cases = json.loads((root/'docs/editor-evaluation-cases.json').read_text())[:args.cases]
code = (root/'Sources/LocalFlowCore/Inference.swift').read_text()
prompts = {mode: re.search(r'case \.'+mode+r': instruction = "([^\n]+)"', code).group(1).replace('\\n', '\n') for mode in ('clean','compose')}
mx.set_cache_limit(128*1024*1024)
started = time.perf_counter()
model, tokenizer = load(str(args.model_path), tokenizer_config={'trust_remote_code': False})
load_seconds = time.perf_counter()-started
rows = []
report = {'engine':'mlx-lm '+importlib.metadata.version('mlx-lm'), 'model_path':args.model_path.name, 'load_s':load_seconds, 'temperature':0, 'thinking':False, 'max_tokens':1200, 'prompts':prompts, 'results':rows}
for mode, instructions in prompts.items():
    for case in cases:
        source = case['text'].replace('Локэлфлоу','LocalFlow')
        messages = [{'role':'system','content':instructions}, {'role':'user','content':'<материал>\n'+source+'\n</материал>'}]
        prompt = tokenizer.apply_chat_template(messages, tokenize=True, add_generation_prompt=True, enable_thinking=False)
        start = time.perf_counter(); pieces = []; first_s = None; final = None
        for chunk in stream_generate(model, tokenizer, prompt, max_tokens=1200, sampler=make_sampler(temp=0)):
            if chunk.text and first_s is None: first_s = time.perf_counter()-start
            pieces.append(chunk.text); final = chunk
        row = {'id':case['id'],'mode':mode,'output':''.join(pieces).strip(),'elapsed_s':time.perf_counter()-start,'first_token_s':first_s,'tokens':final.generation_tokens,'tokens_s':final.generation_tps,'peak_mlx_gb':final.peak_memory,'finish':final.finish_reason}
        rows.append(row)
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
        print(args.model_path.name, mode, case['id'], round(row['elapsed_s'],2), row['finish'], flush=True)
del model, tokenizer, final
mx.synchronize(); gc.collect(); mx.clear_cache()
report['mlx_active_after_unload_bytes'] = mx.get_active_memory()
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
