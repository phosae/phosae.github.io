---
title: "Hugo Test"
summary: "摘要摘要摘要"
date: 2019-10-01T02:01:57+08:00
lastmod: 2019-10-06T22:45:00+08:00
draft: true

keywords: []
description: ""
tags: []
categories: []
author: ""

# You can also close(false) or open(true) something for this content.
# P.S. comment can only be closed
comment: true
toc: true
autoCollapseToc: true
postMetaInFooter: false
hiddenFromHomePage: false
# You can also define another contentCopyright. e.g. contentCopyright: "This is another copyright."
contentCopyright: false
reward: false
mathjax: true
mathjaxEnableSingleDollar: true
mathjaxEnableAutoNumber: true

# You unlisted posts you might want not want the header or footer to show
hideHeaderAndFooter: false

# You can enable or disable out-of-date content warning for individual post.
# Comment this out to use the global config.
#enableOutdatedInfoWarning: false

flowchartDiagrams:
  enable: false
  options: "{
              'x': 0,
              'y': 0,
              'line-width': 3,
              'line-length': 50,
              'text-margin': 10,
              'font-size': 14,
              'font-color': 'black',
              'line-color': 'black',
              'element-color': 'black',
              'fill': 'white',
              'yes-text': 'yes',
              'no-text': 'no',
              'arrow-end': 'block',
              'scale': 1,
              'i-am-a-comment-1': 'Do not use /​/!',
              'i-am-a-comment-2': 'style symbol types',
              'symbols': {
                  'start': {
                    'font-color': 'red',
                    'element-color': 'green',
                    'fill': 'yellow'
                  },
                  'end': {
                      'class': 'end-element'
                  }
              },
              'i-am-a-comment-3': 'even flowstate support ;-)',
              'flowstate': {
                'request': {'fill': 'orange'}
              }
            }"

sequenceDiagrams: 
  enable: false
  options: "{theme: 'simple'}"
---

# 基本操作
我很喜欢 ![](/img/terrace_house_chunhua.jpg)
[大部分来自even 文档]https://github.com/olOwOlo/hugo-theme-even


## Code
    ```python
    import pandas as pd
    data = pd.read_csv("data.csv")
    data.head()
    ```

renders as

```python
import pandas as pd
data = pd.read_csv("data.csv")
data.head()
```

## Math

Academic supports a Markdown extension for $\LaTeX$ math. 

To render *inline* or *block* math, wrap your LaTeX math with `$...$`.

Example **math block**:

```tex
2^k -1 = \sum_{i=0}^{k-1}2^i

2^k\\&\\sum_{i=0}^{k-1}2^i=0
```

renders as

$2^k -1 = \sum_{i=0}^{k-1}2^i$

$2^k\\&\\sum_{i=0}^{k-1}2^i=0$

## admonition

{{% admonition note "I'm title!" false %}}
biu biu biu.

{{% admonition type="note" title="note" details="true" %}}
biu biu biu.
{{% /admonition %}}

{{% admonition example %}}
Without title.
{{% /admonition %}}

{{% /admonition %}}

{{% admonition  warning%}}
zeng: 你想要看什么？
{{% /admonition%}}

{{% admonition%}}
xu: 林志玲。
{{% /admonition %}}

> 你想要什么
> 林志玲

## Todo lists

You can even write your todo lists in Academic too:

```
- [x] Write math example
- [x] Write diagram example
- [ ] Do something else
```

renders as

- [x] Write math example
- [x] Write diagram example
- [ ] Do something else

## Tables

Represent your data in tables:

```
| First Header  | Second Header |
| ------------- | ------------- |
| Content Cell  | Content Cell  |
| Content Cell  | Content Cell  |
```

renders as

| First Header  | Second Header |
| ------------- | ------------- |
| Content Cell  | Content Cell  |
| Content Cell  | Content Cell  |

# Charts
See more information from https://github.com/adrai/flowchart.js.

```flowchart
st=>start: Start|past:>http://www.google.com[blank]
e=>end: End:>http://www.google.com
op1=>operation: My Operation|past
op2=>operation: Stuff|current
sub1=>subroutine: My Subroutine|invalid
cond=>condition: Yes
or No?|approved:>http://www.google.com
c2=>condition: Good idea|rejected
io=>inputoutput: catch something...|request

st->op1(right)->cond
cond(yes, right)->c2
cond(no)->sub1(left)->op1
c2(yes)->io->e
c2(no)->op2->e
```

see more info from https://bramp.github.io/js-sequence-diagrams/

```sequence
Andrew->China: Says Hello
Note right of China: China thinks\nabout it
China-->Andrew: How are you?
Andrew->>China: I am good thanks!
```

```sequence
Title: Here is a title
A->B: Normal line
B-->C: Dashed line
C->>D: Open arrow
D-->>A: Dashed open arrow
```

{{< highlight go-html-template "linenos=table,hl_lines=1 3-7,linenostart=199" >}}
<section id="main">
  <div>
   <h1 id="title">{{ .Title }}</h1>
    {{ range .Data.Pages }}
        {{ .Render "summary"}}
    {{ end }}
  </div>
</section>
{{< / highlight >}}

# music

飞云之下

{{% music id="554242032" auto="1" %}}
