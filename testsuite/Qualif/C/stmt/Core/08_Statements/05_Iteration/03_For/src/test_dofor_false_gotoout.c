#include "dofor.h"

int
main (void)
{
  dofor (10, GOTO_OUT);
  return 0;
}

//# dofor.c
//  /body/      l+ ## 0
//  /goto-in/   l- ## s-
//  /pre-for/   l+ ## 0
//  /eval/      l+ ## 0
//  /for/       l- ## s-
//  /goto-out/  l- ## s-
