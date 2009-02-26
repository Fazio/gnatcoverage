/****************************************************************************
 *                                                                          *
 *                              Couverture                                  *
 *                                                                          *
 *                     Copyright (C) 2008-2009, AdaCore                     *
 *                                                                          *
 * Couverture is free software; you can redistribute it  and/or modify it   *
 * under terms of the GNU General Public License as published by the Free   *
 * Software Foundation; either version 2, or (at your option) any later     *
 * version.  Couverture is distributed in the hope that it will be useful,  *
 * but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHAN-  *
 * TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public *
 * License  for more details. You  should  have  received a copy of the GNU *
 * General Public License  distributed with GNAT; see file COPYING. If not, *
 * write  to  the Free  Software  Foundation,  59 Temple Place - Suite 330, *
 * Boston, MA 02111-1307, USA.                                              *
 *                                                                          *
 ****************************************************************************/
static void outb(int port, unsigned char v)
{
  *((volatile unsigned char *)(0x80000000 + port)) = v;
}

static unsigned char inb(int port)
{
  return *((volatile unsigned char *)(0x80000000 + port));
}

void abort (void)
{
  outb (0x92, 0x01);
  while (1)
    ;
}

int putchar(int c)
{
  outb (0x3f8 + 0x00, c);
  return c;
}

int checkkey (void)
{
  return inb (0x3f8 + 0x05) & 0x01;
}

int getchar (void)
{
  while (!checkkey ())
    ;
  return inb(0x3f8 + 0x00);
}

int fsync (int fd)
{
}

static void memcpy (unsigned char *d, unsigned char *s, int len)
{
  while (len--)
    *d++ = *s++;
}

static void bzero (unsigned char *d, int len)
{
  while (len--)
    *d++ = 0;
}

extern char __sdata2_load[], __sdata2_start[], __sdata2_end[];
extern char __data_load[], __data_start[], __data_end[];
extern char __sbss2_start[], __sbss2_end[];
extern char __sbss_start[], __sbss_end[];
extern char __bss_start[], __bss_end[];

void cmain (void)
{
  memcpy (__sdata2_start, __sdata2_load, __sdata2_end - __sdata2_start);
  memcpy (__data_start, __data_load, __data_end - __data_start);
  bzero (__sbss2_start, __sbss2_end - __sbss2_start);
  bzero (__sbss_start, __sbss_end - __sbss_start);
  bzero (__bss_start, __bss_end - __bss_start);
  main();
  abort ();
}
