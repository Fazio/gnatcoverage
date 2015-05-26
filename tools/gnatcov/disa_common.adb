------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2008-2012, AdaCore                     --
--                                                                          --
-- GNATcoverage is free software; you can redistribute it and/or modify it  --
-- under terms of the GNU General Public License as published by the  Free  --
-- Software  Foundation;  either version 3,  or (at your option) any later  --
-- version. This software is distributed in the hope that it will be useful --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Arch;     use Arch;
with Swaps;    use Swaps;
with Traces;   use Traces;

package body Disa_Common is

   ----------------
   -- ELF_To_U16 --
   ----------------

   function ELF_To_U16 (Bin : Binary_Content) return Unsigned_16 is
      pragma Assert (Length (Bin) = 2);

      type Bin_U16 is array (Elf_Addr range 1 .. 2) of Unsigned_8;

      Bin_Aligned : Bin_U16 := Bin_U16 (Bin.Content (0 .. 1));
      for Bin_Aligned'Alignment use Unsigned_16'Alignment;

      Result : Unsigned_16;
      pragma Import (Ada, Result);
      for Result'Address use Bin_Aligned'Address;
   begin
      if Big_Endian_Host /= Big_Endian_ELF then
         Swap_16 (Result);
      end if;
      return Result;
   end ELF_To_U16;

   ----------------
   -- ELF_To_U32 --
   ----------------

   function ELF_To_U32 (Bin : Binary_Content) return Unsigned_32 is
      pragma Assert (Length (Bin) = 4);

      type Bin_U32 is array (Elf_Addr range 1 .. 4) of Unsigned_8;

      Bin_Aligned : Bin_U32 := Bin_U32 (Bin.Content (0 .. 3));
      for Bin_Aligned'Alignment use Unsigned_32'Alignment;

      Result : Unsigned_32;
      pragma Import (Ada, Result);
      for Result'Address use Bin_Aligned'Address;
   begin
      if Big_Endian_Host /= Big_Endian_ELF then
         Swap_32 (Result);
      end if;
      return Result;
   end ELF_To_U32;

   -----------------------
   -- To_Big_Endian_U32 --
   -----------------------

   function To_Big_Endian_U32 (Bin : Binary_Content) return Unsigned_32 is
      pragma Assert (Length (Bin) = 4);

      type Bin_U32 is array (Elf_Addr range 1 .. 4) of Unsigned_8;

      Bin_Aligned : Bin_U32 := Bin_U32 (Bin.Content (0 .. 3));
      for Bin_Aligned'Alignment use Unsigned_32'Alignment;

      Result : Unsigned_32;
      pragma Import (Ada, Result);
      for Result'Address use Bin_Aligned'Address;
   begin
      if not Big_Endian_Host then
         Swap_32 (Result);
      end if;
      return Result;
   end To_Big_Endian_U32;

end Disa_Common;
