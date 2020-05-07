---
title: "{{ replace .TranslationBaseName "-" " " | title }}"
date: {{ .Date }}
lastmod: {{ .Date }}
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
# You can also define another contentCopyright. e.g. contentCopyright: "This is another copyright."
contentCopyright:  '本作品采用 <a rel="license noopener" href="https://creativecommons.org/licenses/by-nc-nd/4.0/" target="_blank">知识共享署名-非商业性使用-禁止演绎 4.0 国际许可协议</a> 进行许可，转载时请注明原文链接。'    
reward: false
mathjax: false
mathjaxEnableSingleDollar: false
mathjaxEnableAutoNumber: false

# You unlisted posts you might want not want the header or footer to show
hideHeaderAndFooter: true

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