FROM lethalfang/somaticseq:base-1.1

MAINTAINER Li Tai Fang <li_tai.fang@roche.com>

RUN cd /opt && git clone https://github.com/bioinform/somaticseq
