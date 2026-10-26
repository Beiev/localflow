#!/usr/bin/env python3
"""Refresh only when intentionally upgrading reviewed model revisions."""
import json, urllib.request
from pathlib import Path
configs = [
 ('asr8','Распознавание речи','FluidInference/parakeet-tdt-0.6b-v3-coreml','7dd20fe6b1797d35f5e3307e8b1732d9a178edfe','parakeet-tdt-0.6b-v3',['Preprocessor.mlmodelc','Encoder.mlmodelc','Decoder.mlmodelc','JointDecisionv3.mlmodelc','parakeet_vocab.json']),
 ('editor','Редактирование · Gemma 4 E2B','mlx-community/gemma-4-e2b-it-4bit','238767527555cb75a05732a84dff5d6ba0dd6809','gemma-4-e2b',['chat_template.jinja','config.json','generation_config.json','model.safetensors','model.safetensors.index.json','processor_config.json','tokenizer.json','tokenizer_config.json']),
 ('editor-qwen','Редактирование · Qwen 4B','mlx-community/Qwen3-4B-Instruct-2507-4bit','50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b','qwen3-4b',['config.json','model.safetensors','model.safetensors.index.json','tokenizer.json','tokenizer_config.json','special_tokens_map.json','added_tokens.json','chat_template.jinja','merges.txt','vocab.json','generation_config.json']),
 ('editor-qwen9','Редактирование · Qwen 3.5 9B','mlx-community/Qwen3.5-9B-4bit','8b2b98c00a6b4d291155e4890773ca8f769aee53','qwen3.5-9b',['config.json','model-00001-of-00002.safetensors','model-00002-of-00002.safetensors','model.safetensors.index.json','tokenizer.json','tokenizer_config.json','vocab.json','chat_template.jinja','preprocessor_config.json','processor_config.json']),
 ('speakers','Разделение голосов','FluidInference/speaker-diarization-coreml','1ed7a662fdc7109e36d822db793ee6eebdaf8594','speaker-diarization',['Segmentation.mlmodelc','FBank.mlmodelc','Embedding.mlmodelc','PldaRho.mlmodelc','plda-parameters.json'])
]
cache={}; result=[]
for ident,title,repo,rev,folder,roots in configs:
 if repo not in cache: cache[repo]=json.load(urllib.request.urlopen(f'https://huggingface.co/api/models/{repo}/revision/{rev}?blobs=true'))
 files=[]
 for f in cache[repo]['siblings']:
  if f['rfilename'].split('/')[0] in roots:
   files.append({'path':f['rfilename'],'size':f['size'],'hash':f.get('lfs',{}).get('sha256',f['blobId']),'sha256':'lfs' in f})
 result.append(dict(id=ident,title=title,repo=repo,revision=rev,folder=folder,files=files))
 print(ident,len(files),round(sum(f['size'] for f in files)/1e6),'MB')
Path('Sources/LocalFlowCore/Resources/models.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
