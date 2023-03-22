---
title: "K8s Apiserver 1"
date: 2021-06-11T10:25:01+08:00
lastmod: 2021-06-11T10:25:01+08:00
draft: true
keywords: []
description: ""
tags: []
author: "Zeng Xu"
summary: "文章摘要"

comment: true
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
contentCopyright:  '本作品采用 <a rel="license noopener" href="https://creativecommons.org/licenses/by-nc-nd/4.0/" target="_blank">知识共享署名-非商业性使用-禁止演绎 4.0 国际许可协议</a> 进行许可，转载时请注明原文链接。'    
reward: false
mathjax: false
mathjaxEnableSingleDollar: false
mathjaxEnableAutoNumber: false

# You unlisted posts you might want not want the header or footer to show
hideHeaderAndFooter: false

# You can enable or disable out-of-date content warning for individual post.
# Comment this out to use the global config.
#enableOutdatedInfoWarning: false

flowchartDiagrams:
  enable: false
  options: ""

sequenceDiagrams: 
  enable: false
  options: ""
---

## Limitations

- Currently, only LLaMA-7B is supported since I haven't figured out how to merge the tensors of the bigger models. However, in theory, you should be able to run 65B on a 64GB MacBook
- Not sure if my tokenizer is correct. There are a few places where we might have a mistake:
  - https://github.com/ggerganov/llama.cpp/blob/26c084662903ddaca19bef982831bfb0856e8257/convert-pth-to-ggml.py#L79-L87
  - https://github.com/ggerganov/llama.cpp/blob/26c084662903ddaca19bef982831bfb0856e8257/utils.h#L65-L69
  
  **In** general, it seems to work, but I think it fails for unicode character support. Hopefully, someone can help with that
- I don't know yet how much the quantization affects the quality of the generated text
- Probably the token sampling can be improved
- x86 quantization support [not yet ready](https://github.com/ggerganov/ggml/pull/27). Basically, you want to run this on Apple Silicon. For now, on Linux and Windows you can use the F16 `ggml-model-f16.bin` model, but it will be much slower.
