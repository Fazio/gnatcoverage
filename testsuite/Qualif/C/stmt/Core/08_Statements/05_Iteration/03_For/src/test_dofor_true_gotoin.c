#include "dofor.h"

int
main (void)
{
  dofor (0, GOTO_IN);
  return 0;
}

//# dofor.c
//  /body/      l+ ## 0
//  /goto-in/   l+ ## 0
//  /eval/      l+ ## 0
//  /for/       l+ ## 0
//  /goto-out/  l- ## s-
