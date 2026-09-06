#!/usr/bin/env python3
"""Refresh only when intentionally upgrading reviewed model revisions."""
import json, urllib.request
from pathlib import Path
configs = [
 ('asr8','Распознавание · баланс','FluidInference/parakeet-tdt-0.6b-v3-coreml','7dd20fe6b1797d35f5e3307e8b1732d9a178edfe','parakeet-tdt-0.6b-v3',['Preprocessor.mlmodelc','Encoder.mlmodelc','Decoder.mlmodelc','JointDecisionv3.mlmodelc','parakeet_vocab.json']),
 ('asr4','Распознавание · компактное','FluidInference/parakeet-tdt-0.6b-v3-coreml','7dd20fe6b1797d35f5e3307e8b1732d9a178edfe','parakeet-tdt-0.6b-v3',['Preprocessor.mlmodelc','EncoderInt4.mlmodelc','Decoder.mlmodelc','JointDecisionv3.mlmodelc','parakeet_vocab.json']),
 ('editor','Редактирование · Qwen 4B','mlx-community/Qwen3-4B-Instruct-2507-4bit','50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b','qwen3-4b',['config.json','model.safetensors','model.safetensors.index.json','tokenizer.json','tokenizer_config.json','special_tokens_map.json','added_tokens.json','chat_template.jinja','merges.txt','vocab.json','generation_config.json']),
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
