------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                        Copyright (C) 2008, AdaCore                       --
--                                                                          --
-- Couverture is free software; you can redistribute it  and/or modify it   --
-- under terms of the GNU General Public License as published by the Free   --
-- Software Foundation; either version 2, or (at your option) any later     --
-- version.  Couverture is distributed in the hope that it will be useful,  --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHAN-  --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License  for more details. You  should  have  received a copy of the GNU --
-- General Public License  distributed with GNAT; see file COPYING. If not, --
-- write  to  the Free  Software  Foundation,  59 Temple Place - Suite 330, --
-- Boston, MA 02111-1307, USA.                                              --
--                                                                          --
------------------------------------------------------------------------------
with Ada.Unchecked_Conversion;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Containers.Vectors;
with Elf_Common; use Elf_Common;
with Elf32;
with Interfaces; use Interfaces;
with Hex_Images; use Hex_Images;
with Elf_Arch; use Elf_Arch;
with Dwarf;
with Dwarf_Handling;  use Dwarf_Handling;
with System; use System;
with System.Storage_Elements; use System.Storage_Elements;
with Traces_Sources;
with Disa_Ppc;
with Elf_Files; use Elf_Files;
with Traces_Names;

package body Traces_Elf is
   Empty_String_Acc : constant String_Acc := new String'("");

   function "<" (L, R : Addresses_Info_Acc) return Boolean is
   begin
      return L.Last < R.First;
   end "<";

   Sections_Set : Addresses_Containers.Set;
   Compile_Units_Set : Addresses_Containers.Set;
   Subprograms_Set : Addresses_Containers.Set;
   Symbols_Set : Addresses_Containers.Set;
   Lines_Set : Addresses_Containers.Set;

   type Disassemble_Cb is access procedure (Addr : Pc_Type;
                                            State : Trace_State;
                                            Insn : Binary_Content);

   procedure Disassemble (Insns : Binary_Content;
                          State : Trace_State;
                          Cb : Disassemble_Cb);

   procedure Disp_Address (El : Addresses_Info_Acc) is
   begin
      Put (Hex_Image (El.First) & '-' & Hex_Image (El.Last));
      case El.Kind is
         when Section_Addresses =>
            Put_Line (" section " & El.Section_Name.all);
         when Compile_Unit_Addresses =>
            Put_Line (" compile unit from " & El.Compile_Unit_Filename.all);
         when Subprogram_Addresses =>
            Put_Line (" subprogram " & El.Subprogram_Name.all);
         when Symbol_Addresses =>
            Put_Line (" symbol for " & El.Symbol_Name.all);
         when Line_Addresses =>
            Put_Line (" line " & El.Line_Filename.all & ':'
                      & Natural'Image (El.Line_Number));
      end case;
      if False and El.Parent /= null then
         Put (" parent: ");
         Disp_Address (El.Parent);
      end if;
   end Disp_Address;

   procedure Disp_Addresses (Set : Addresses_Containers.Set)
   is
      use Addresses_Containers;
      Cur : Cursor;
      El : Addresses_Info_Acc;
   begin
      Cur := First (Set);
      while Cur /= No_Element loop
         El := Element (Cur);
         Disp_Address (El);
         Next (Cur);
      end loop;
   end Disp_Addresses;

   procedure Insert (Set : in out Addresses_Containers.Set;
                     El : Addresses_Info_Acc)
     renames Addresses_Containers.Insert;

   procedure Disp_Sections_Addresses is
   begin
      Disp_Addresses (Sections_Set);
   end Disp_Sections_Addresses;

   procedure Disp_Compile_Units_Addresses is
   begin
      Disp_Addresses (Compile_Units_Set);
   end Disp_Compile_Units_Addresses;

   procedure Disp_Subprograms_Addresses is
   begin
      Disp_Addresses (Subprograms_Set);
   end Disp_Subprograms_Addresses;

   procedure Disp_Symbols_Addresses is
   begin
      Disp_Addresses (Symbols_Set);
   end Disp_Symbols_Addresses;

   procedure Disp_Lines_Addresses is
   begin
      Disp_Addresses (Lines_Set);
   end Disp_Lines_Addresses;

   --  Sections index.
   Sec_Debug_Abbrev   : Elf_Half := 0;
   Sec_Debug_Info     : Elf_Half := 0;
   Sec_Debug_Info_Rel : Elf_Half := 0;
   Sec_Debug_Line     : Elf_Half := 0;
   Sec_Debug_Line_Rel : Elf_Half := 0;
   Sec_Debug_Str      : Elf_Half := 0;

   Exe_File : Elf_File;
   Exe_Text_Start : Elf_Addr;
   Exe_Machine : Elf_Half;
   Is_Big_Endian : Boolean;

   --  FIXME.
   Addr_Size : Natural := 0;

   Debug_Str_Base : Address := Null_Address;
   Debug_Str_Len : Elf_Size;
   Debug_Strs : Binary_Content_Acc;

   --  .debug_lines content.
   Lines_Len : Elf_Size := 0;
   Lines : Binary_Content_Acc := null;

   Bad_Stmt_List : constant Unsigned_64 := Unsigned_64'Last;

   procedure Open_File (Filename : String; Text_Start : Pc_Type)
   is
      Ehdr : Elf_Ehdr;
   begin
      Open_File (Exe_File, Filename);
      Exe_Text_Start := Text_Start;
      Ehdr := Get_Ehdr (Exe_File);
      Is_Big_Endian := Ehdr.E_Ident (EI_DATA) = ELFDATA2MSB;
      Exe_Machine := Ehdr.E_Machine;

      --  Be sure the section headers are loaded.
      Load_Shdr (Exe_File);

      for I in 0 .. Get_Shdr_Num (Exe_File) - 1 loop
         declare
            Name : constant String := Get_Shdr_Name (Exe_File, I);
         begin
            if Name = ".debug_abbrev" then
               Sec_Debug_Abbrev := I;
            elsif Name = ".debug_info" then
               Sec_Debug_Info := I;
            elsif Name = ".rela.debug_info" then
               Sec_Debug_Info_Rel := I;
            elsif Name = ".debug_line" then
               Sec_Debug_Line := I;
            elsif Name = ".rela.debug_line" then
               Sec_Debug_Line_Rel := I;
            elsif Name = ".debug_str" then
               Sec_Debug_Str := I;
            end if;
         end;
      end loop;
   end Open_File;

   procedure Read_Word8 (Base : Address;
                         Off : in out Storage_Offset;
                         Res : out Unsigned_64) is
   begin
      if Is_Big_Endian then
         Read_Word8_Be (Base, Off, Res);
      else
         Read_Word8_Le (Base, Off, Res);
      end if;
   end Read_Word8;

   procedure Read_Word4 (Base : Address;
                         Off : in out Storage_Offset;
                         Res : out Unsigned_32) is
   begin
      if Is_Big_Endian then
         Read_Word4_Be (Base, Off, Res);
      else
         Read_Word4_Le (Base, Off, Res);
      end if;
   end Read_Word4;

   procedure Read_Word4 (Base : Address;
                         Off : in out Storage_Offset;
                         Res : out Integer_32)
   is
      function To_Integer_32 is new Ada.Unchecked_Conversion
        (Unsigned_32, Integer_32);
      R : Unsigned_32;
   begin
      Read_Word4 (Base, Off, R);
      Res := To_Integer_32 (R);
   end Read_Word4;

   procedure Read_Word2 (Base : Address;
                         Off : in out Storage_Offset;
                         Res : out Unsigned_16) is
   begin
      if Is_Big_Endian then
         Read_Word2_Be (Base, Off, Res);
      else
         Read_Word2_Le (Base, Off, Res);
      end if;
   end Read_Word2;

   procedure Write_Word4 (Base : Address;
                          Off : in out Storage_Offset;
                          Val : Unsigned_32) is
   begin
      if Is_Big_Endian then
         Write_Word4_Be (Base, Off, Val);
      else
         Write_Word4_Le (Base, Off, Val);
      end if;
   end Write_Word4;

   procedure Write_Word4 (Base : Address;
                          Off : in out Storage_Offset;
                          Val : Integer_32)
   is
      function To_Unsigned_32 is new Ada.Unchecked_Conversion
        (Integer_32, Unsigned_32);
      R : Unsigned_32;
   begin
      R := To_Unsigned_32 (Val);
      Write_Word4 (Base, Off, R);
   end Write_Word4;

   procedure Read_Address (Base : Address;
                           Off : in out Storage_Offset;
                           Sz : Natural;
                           Res : out Unsigned_64)
   is
   begin
      if Sz = 4 then
         declare
            V : Unsigned_32;
         begin
            Read_Word4 (Base, Off, V);
            Res := Unsigned_64 (V);
         end;
      elsif Sz = 8 then
         Read_Word8 (Base, Off, Res);
      else
         raise Program_Error;
      end if;
   end Read_Address;

   procedure Read_Dwarf_Form_U64 (Base : Address;
                                  Off : in out Storage_Offset;
                                  Form : Unsigned_32;
                                  Res : out Unsigned_64)
   is
      use Dwarf;
   begin
      case Form is
         when DW_FORM_Addr =>
            Read_Address (Base, Off, Addr_Size, Res);
         when DW_FORM_Flag =>
            declare
               V : Unsigned_8;
            begin
               Read_Byte (Base, Off, V);
               Res := Unsigned_64 (V);
            end;
         when DW_FORM_Data1 =>
            declare
               V : Unsigned_8;
            begin
               Read_Byte (Base, Off, V);
               Res := Unsigned_64 (V);
            end;
         when DW_FORM_Data2 =>
            declare
               V : Unsigned_16;
            begin
               Read_Word2 (Base, Off, V);
               Res := Unsigned_64 (V);
            end;
         when DW_FORM_Data4
            | DW_FORM_Ref4 =>
            declare
               V : Unsigned_32;
            begin
               Read_Word4 (Base, Off, V);
               Res := Unsigned_64 (V);
            end;
         when DW_FORM_Data8 =>
            Read_Word8 (Base, Off, Res);
         when DW_FORM_Sdata =>
            declare
               V : Unsigned_32;
            begin
               Read_SLEB128 (Base, Off, V);
               Res := Unsigned_64 (V);
            end;
         when DW_FORM_Udata =>
            declare
               V : Unsigned_32;
            begin
               Read_ULEB128 (Base, Off, V);
               Res := Unsigned_64 (V);
            end;
         when DW_FORM_Strp
           | DW_FORM_String
           | DW_FORM_Block1 =>
            raise Program_Error;
         when others =>
            raise Program_Error;
      end case;
   end Read_Dwarf_Form_U64;

   procedure Read_Dwarf_Form_String (Base : Address;
                                     Off : in out Storage_Offset;
                                     Form : Unsigned_32;
                                     Res : out Address)
   is
      use Dwarf;
   begin
      case Form is
         when DW_FORM_Strp =>
            declare
               V : Unsigned_32;
            begin
               Read_Word4 (Base, Off, V);
               if Debug_Str_Base = Null_Address then
                  if Sec_Debug_Str /= 0 then
                     Debug_Str_Len := Get_Section_Length
                       (Exe_File, Sec_Debug_Str);
                     Debug_Strs := new Binary_Content (0 .. Debug_Str_Len - 1);
                     Debug_Str_Base := Debug_Strs (0)'Address;
                     Load_Section (Exe_File, Sec_Debug_Str, Debug_Str_Base);
                  else
                     return;
                  end if;
               end if;
               Res := Debug_Str_Base + Storage_Offset (V);
            end;
         when DW_FORM_String =>
            Res := Base + Off;
            declare
               C : Unsigned_8;
            begin
               loop
                  Read_Byte (Base, Off, C);
                  exit when C = 0;
               end loop;
            end;
         when others =>
            Put ("???");
            raise Program_Error;
      end case;
   end Read_Dwarf_Form_String;

   procedure Skip_Dwarf_Form (Base : Address;
                              Off : in out Storage_Offset;
                              Form : Unsigned_32)
   is
      use Dwarf;
   begin
      case Form is
         when DW_FORM_Addr =>
            Off := Off + Storage_Offset (Addr_Size);
         when DW_FORM_Block1 =>
            declare
               V : Unsigned_8;
            begin
               Read_Byte (Base, Off, V);
               Off := Off + Storage_Offset (V);
            end;
         when DW_FORM_Flag
           | DW_FORM_Data1 =>
            Off := Off + 1;
         when DW_FORM_Data2 =>
            Off := Off + 2;
         when DW_FORM_Data4
           | DW_FORM_Ref4
           | DW_FORM_Strp =>
            Off := Off + 4;
         when DW_FORM_Data8 =>
            Off := Off + 8;
         when DW_FORM_Sdata =>
            declare
               V : Unsigned_32;
            begin
               Read_SLEB128 (Base, Off, V);
            end;
         when DW_FORM_Udata =>
            declare
               V : Unsigned_32;
            begin
               Read_ULEB128 (Base, Off, V);
            end;
         when DW_FORM_String =>
            declare
               C : Unsigned_8;
            begin
               loop
                  Read_Byte (Base, Off, C);
                  exit when C = 0;
               end loop;
            end;
         when others =>
            Put ("???");
            raise Program_Error;
      end case;
   end Skip_Dwarf_Form;

   procedure Apply_Relocations (Sec_Rel : Elf_Half;
                                Data : in out Binary_Content)
   is
      use Elf32;
      Relocs_Len : Elf_Size;
      Relocs : Binary_Content_Acc;
      Relocs_Base : Address;

      Shdr : Elf_Shdr_Acc;
      Off : Storage_Offset;

      R : Elf_Rela;
   begin
      Shdr := Get_Shdr (Exe_File, Sec_Rel);
      if Shdr.Sh_Type /= SHT_RELA then
         raise Program_Error;
      end if;
      if Natural (Shdr.Sh_Entsize) /= Elf_Rela_Size then
         raise Program_Error;
      end if;
      Relocs_Len := Get_Section_Length (Exe_File, Sec_Rel);
      Relocs := new Binary_Content (0 .. Relocs_Len - 1);
      Load_Section (Exe_File, Sec_Rel, Relocs (0)'Address);
      Relocs_Base := Relocs (0)'Address;

      Off := 0;
      while Off < Storage_Offset (Relocs_Len) loop
         if
           Off + Storage_Offset (Elf_Rela_Size) > Storage_Offset (Relocs_Len)
         then
            --  Truncated.
            raise Program_Error;
         end if;

         --  Read relocation entry.
         Read_Word4 (Relocs_Base, Off, R.R_Offset);
         Read_Word4 (Relocs_Base, Off, R.R_Info);
         Read_Word4 (Relocs_Base, Off, R.R_Addend);

         if R.R_Offset > Data'Last then
            raise Program_Error;
         end if;

         case Exe_Machine is
            when EM_PPC =>
               case Elf_R_Type (R.R_Info) is
                  when R_PPC_ADDR32 =>
                     null;
                  when others =>
                     raise Program_Error;
               end case;
            when others =>
               raise Program_Error;
         end case;

         Write_Word4 (Data (0)'Address,
                      Storage_Offset (R.R_Offset), R.R_Addend);
      end loop;
      Unchecked_Deallocation (Relocs);
   end Apply_Relocations;

   function Get_Section_By_Addr (Pc : Pc_Type) return Addresses_Info_Acc;

   --  Extract lang, subprogram name and stmt_list (offset in .debug_line).
   procedure Build_Debug_Compile_Units
   is
      use Dwarf;

      Abbrev_Len : Elf_Size;
      Abbrevs : Binary_Content_Acc;
      Abbrev_Base : Address;
      Map : Abbrev_Map_Acc;
      Abbrev : Address;

      Shdr : Elf_Shdr_Acc;
      Info_Len : Elf_Size;
      Infos : Binary_Content_Acc;
      Base : Address;
      Off : Storage_Offset;
      Aoff : Storage_Offset;

      Len : Unsigned_32;
      Ver : Unsigned_16;
      Abbrev_Off : Unsigned_32;
      Ptr_Sz : Unsigned_8;
      Last : Storage_Offset;
      Num : Unsigned_32;

      Tag : Unsigned_32;
      Name : Unsigned_32;
      Form : Unsigned_32;

      Level : Unsigned_8;

      At_Sib : Unsigned_64 := 0;
      At_Stmt_List : Unsigned_64 := Bad_Stmt_List;
      At_Low_Pc : Unsigned_64;
      At_High_Pc : Unsigned_64;
      At_Lang : Unsigned_64 := 0;
      At_Name : Address := Null_Address;
      Cu_Base_Pc : Unsigned_64;

      Current_Cu : Addresses_Info_Acc;
      Current_Subprg : Addresses_Info_Acc;
      Addr : Pc_Type;
   begin
      --  Return now if already loaded.
      if not Compile_Units_Set.Is_Empty then
         return;
      end if;

      if Sections_Set.Is_Empty then
         raise Program_Error;
      end if;

      --  Load .debug_abbrev
      Abbrev_Len := Get_Section_Length (Exe_File, Sec_Debug_Abbrev);
      Abbrevs := new Binary_Content (0 .. Abbrev_Len - 1);
      Abbrev_Base := Abbrevs (0)'Address;
      Load_Section (Exe_File, Sec_Debug_Abbrev, Abbrev_Base);

      Map := null;

      --  Load .debug_info
      Shdr := Get_Shdr (Exe_File, Sec_Debug_Info);
      Info_Len := Get_Section_Length (Exe_File, Sec_Debug_Info);
      Infos := new Binary_Content (0 .. Info_Len - 1);
      Base := Infos (0)'Address;
      Load_Section (Exe_File, Sec_Debug_Info, Base);

      if Sec_Debug_Info_Rel /= 0 then
         Apply_Relocations (Sec_Debug_Info_Rel, Infos.all);
      end if;

      Off := 0;

      while Off < Storage_Offset (Shdr.Sh_Size) loop
         --  Read .debug_info header:
         --    Length, version, offset in .debug_abbrev, pointer size.
         Read_Word4 (Base, Off, Len);
         Last := Off + Storage_Offset (Len);
         Read_Word2 (Base, Off, Ver);
         Read_Word4 (Base, Off, Abbrev_Off);
         Read_Byte (Base, Off, Ptr_Sz);
         if Ver /= 2 and Ver /= 3 then
            exit;
         end if;
         Level := 0;

         Addr_Size := Natural (Ptr_Sz);
         Cu_Base_Pc := 0;

         Build_Abbrev_Map (Abbrev_Base + Storage_Offset (Abbrev_Off), Map);

         --  Read DIEs.
         loop
            << Again >> null;
            exit when Off >= Last;
            Read_ULEB128 (Base, Off, Num);
            if Num = 0 then
               Level := Level - 1;
               goto Again;
            end if;
            if Num <= Map.all'Last then
               Abbrev := Map (Num);
            else
               Abbrev := Null_Address;
            end if;
            if Abbrev = Null_Address then
               Put ("!! abbrev #" & Hex_Image (Num) & " does not exist !!");
               New_Line;
               return;
            end if;

            --  Read tag
            Aoff := 0;
            Read_ULEB128 (Abbrev, Aoff, Tag);

            if Read_Byte (Abbrev + Aoff) /= 0 then
               Level := Level + 1;
            end if;
            --  skip child.
            Aoff := Aoff + 1;

            --  Read attributes.
            loop
               Read_ULEB128 (Abbrev, Aoff, Name);
               Read_ULEB128 (Abbrev, Aoff, Form);
               exit when Name = 0 and Form = 0;

               case Name is
                  when DW_AT_Sibling =>
                     Read_Dwarf_Form_U64 (Base, Off, Form, At_Sib);
                  when DW_AT_Name =>
                     Read_Dwarf_Form_String (Base, Off, Form, At_Name);
                  when DW_AT_Stmt_List =>
                     Read_Dwarf_Form_U64 (Base, Off, Form, At_Stmt_List);
                  when DW_AT_Low_Pc =>
                     Read_Dwarf_Form_U64 (Base, Off, Form, At_Low_Pc);
                     if Form /= DW_FORM_Addr then
                        At_Low_Pc := At_Low_Pc + Cu_Base_Pc;
                     end if;
                  when DW_AT_High_Pc =>
                     Read_Dwarf_Form_U64 (Base, Off, Form, At_High_Pc);
                     if Form /= DW_FORM_Addr then
                        At_High_Pc := At_High_Pc + Cu_Base_Pc;
                     end if;
                  when DW_AT_Language =>
                     Read_Dwarf_Form_U64 (Base, Off, Form, At_Lang);
                  when others =>
                     Skip_Dwarf_Form (Base, Off, Form);
               end case;
            end loop;
            case Tag is
               when DW_TAG_Compile_Unit =>
                  if At_Low_Pc = 0 and At_High_Pc = 0 then
                     --  This field are not required.
                     At_Low_Pc := 1;
                     At_High_Pc := 1;
                  else
                     Cu_Base_Pc := At_Low_Pc;
                  end if;
                  Addr := Exe_Text_Start + Pc_Type (At_Low_Pc);
                  Current_Cu := new Addresses_Info'
                    (Kind => Compile_Unit_Addresses,
                     First => Addr,
                     Last => Exe_Text_Start + Pc_Type (At_High_Pc - 1),
                     Parent => Get_Section_By_Addr (Addr),
                     Compile_Unit_Filename =>
                       new String'(Read_String (At_Name)),
                     Stmt_List => Unsigned_32 (At_Stmt_List));
                  if At_High_Pc > At_Low_Pc then
                     --  Do not insert empty units.
                     Insert (Compile_Units_Set, Current_Cu);
                  end if;
                  --  Ctxt.Lang := At_Lang;
                  At_Lang := 0;
                  At_Stmt_List := Bad_Stmt_List;
               when DW_TAG_Subprogram =>
                  if At_High_Pc > At_Low_Pc then
                     Current_Subprg :=
                       new Addresses_Info'
                       (Kind => Subprogram_Addresses,
                        First => Exe_Text_Start + Pc_Type (At_Low_Pc),
                        Last => Exe_Text_Start + Pc_Type (At_High_Pc - 1),
                        Parent => Current_Cu,
                        Subprogram_Name =>
                          new String'(Read_String (At_Name)));
                     Insert (Subprograms_Set, Current_Subprg);
                  end if;
               when others =>
                  null;
            end case;
            At_Low_Pc := 0;
            At_High_Pc := 0;

            At_Name := Null_Address;
         end loop;
         Unchecked_Deallocation (Map);
      end loop;

      Unchecked_Deallocation (Infos);
      Unchecked_Deallocation (Abbrevs);
   end Build_Debug_Compile_Units;

   package Filenames_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive,
      Element_Type => String_Acc,
      "=" => "=");

   procedure Read_Debug_Line (CU_Offset : Unsigned_32)
   is
      use Dwarf;
      Base : Address;
      Off : Storage_Offset;

      type Opc_Length_Type is array (Unsigned_8 range <>) of Unsigned_8;
      type Opc_Length_Acc is access Opc_Length_Type;
      Opc_Length : Opc_Length_Acc;

      procedure Unchecked_Deallocation is new Ada.Unchecked_Deallocation
        (Opc_Length_Type, Opc_Length_Acc);

      Total_Len : Unsigned_32;
      Version : Unsigned_16;
      Prolog_Len : Unsigned_32;
      Min_Insn_Len : Unsigned_8;
      Dflt_Is_Stmt : Unsigned_8;
      Line_Base : Unsigned_8;
      Line_Range : Unsigned_8;
      Opc_Base : Unsigned_8;

      B : Unsigned_8;
      Arg : Unsigned_32;

      Old_Off : Storage_Offset;
      File_Dir : Unsigned_32;
      File_Time : Unsigned_32;
      File_Len : Unsigned_32;

      Ext_Len : Unsigned_32;
      Ext_Opc : Unsigned_8;

      Last : Storage_Offset;

      Pc : Unsigned_64;
      Line : Unsigned_32;
      File : Natural;
      Line_Base2 : Unsigned_32;

      Nbr_Dirnames : Unsigned_32;
      Nbr_Filenames : Unsigned_32;
      Dirnames : Filenames_Vectors.Vector;
      Filenames : Filenames_Vectors.Vector;
      Dir : String_Acc;

      procedure New_Raw is
      begin
         --  Note: Last and Parent are set by Build_Debug_Lines.
         Insert (Lines_Set,
                 new Addresses_Info'
                 (Kind => Line_Addresses,
                  First => Exe_Text_Start + Pc_Type (Pc),
                  Last => Exe_Text_Start + Pc_Type (Pc),
                  Parent => null,
                  Line_Next => null,
                  Line_Filename => Filenames_Vectors.Element (Filenames, File),
                  Line_Number => Natural (Line)));
         --  Put_Line ("pc: " & Hex_Image (Pc)
         --        & " file (" & Natural'Image (File) & "): "
         --        & Read_String (Filenames_Vectors.Element (Filenames, File))
         --        & ", line: " & Unsigned_32'Image (Line));
      end New_Raw;
   begin
      --  Load .debug_line
      if Lines = null then
         Lines_Len := Get_Section_Length (Exe_File, Sec_Debug_Line);
         Lines := new Binary_Content (0 .. Lines_Len - 1);
         Load_Section (Exe_File, Sec_Debug_Line, Lines (0)'Address);

         if Sec_Debug_Line_Rel /= 0 then
            Apply_Relocations (Sec_Debug_Line_Rel, Lines.all);
         end if;
      end if;

      Base := Lines (0)'Address;

      Off := Storage_Offset (CU_Offset);
      if Off
        >= Storage_Offset (Get_Section_Length (Exe_File, Sec_Debug_Line))
      then
         return;
      end if;

      --  Read header.
      Read_Word4 (Base, Off, Total_Len);
      Last := Off + Storage_Offset (Total_Len);
      Read_Word2 (Base, Off, Version);
      Read_Word4 (Base, Off, Prolog_Len);
      Read_Byte (Base, Off, Min_Insn_Len);
      Read_Byte (Base, Off, Dflt_Is_Stmt);
      Read_Byte (Base, Off, Line_Base);
      Read_Byte (Base, Off, Line_Range);
      Read_Byte (Base, Off, Opc_Base);

      Pc := 0;
      Line := 1;
      File := 1;

      Line_Base2 := Unsigned_32 (Line_Base);
      if (Line_Base and 16#80#) /= 0 then
         Line_Base2 := Line_Base2 or 16#Ff_Ff_Ff_00#;
      end if;
      Opc_Length := new Opc_Length_Type (1 .. Opc_Base - 1);
      for I in 1 .. Opc_Base - 1 loop
         Read_Byte (Base, Off, Opc_Length (I));
      end loop;

      --  Include directories.
      Nbr_Dirnames := 0;
      Filenames_Vectors.Clear (Dirnames);
      loop
         B := Read_Byte (Base + Off);
         exit when B = 0;
         Filenames_Vectors.Append
           (Dirnames, new String'(Read_String (Base + Off) & '/'));
         Read_String (Base, Off);
         Nbr_Dirnames := Nbr_Dirnames + 1;
      end loop;
      Off := Off + 1;

      --  File names.
      Nbr_Filenames := 0;
      Filenames_Vectors.Clear (Filenames);
      loop
         B := Read_Byte (Base + Off);
         exit when B = 0;
         Old_Off := Off;
         Read_String (Base, Off);
         Read_ULEB128 (Base, Off, File_Dir);
         if File_Dir = 0 or else File_Dir > Nbr_Dirnames then
            Dir := Empty_String_Acc;
         else
            Dir := Filenames_Vectors.Element (Dirnames, Integer (File_Dir));
         end if;
         Filenames_Vectors.Append
           (Filenames, new String'(Dir.all & Read_String (Base + Old_Off)));
         Read_ULEB128 (Base, Off, File_Time);
         Read_ULEB128 (Base, Off, File_Len);
         Nbr_Filenames := Nbr_Filenames + 1;
      end loop;
      Off := Off + 1;

      while Off < Last loop
         --  Read code.
         Read_Byte (Base, Off, B);
         Old_Off := Off;

         if B < Opc_Base then
            case B is
               when 0 =>
                  Read_ULEB128 (Base, Off, Ext_Len);
                  Old_Off := Off;
                  Read_Byte (Base, Off, Ext_Opc);
                  case Ext_Opc is
                     when DW_LNE_Set_Address =>
                        Read_Address
                          (Base, Off, Elf_Arch.Elf_Addr'Size / 8, Pc);
                     when others =>
                        null;
                  end case;
                  Off := Old_Off + Storage_Offset (Ext_Len);
                  --  raise Program_Error;
               when others =>
                  for J in 1 .. Opc_Length (B) loop
                     Read_ULEB128 (Base, Off, Arg);
                  end loop;
            end case;
            case B is
               when DW_LNS_Copy =>
                  New_Raw;
               when DW_LNS_Advance_Pc =>
                  Read_ULEB128 (Base, Old_Off, Arg);
                  Pc := Pc + Unsigned_64 (Arg * Unsigned_32 (Min_Insn_Len));
               when DW_LNS_Advance_Line =>
                  Read_SLEB128 (Base, Old_Off, Arg);
                  Line := Line + Arg;
               when DW_LNS_Set_File =>
                  Read_SLEB128 (Base, Old_Off, Arg);
                  File := Natural (Arg);
               when DW_LNS_Set_Column =>
                  null;
               when DW_LNS_Negate_Stmt =>
                  null;
               when DW_LNS_Set_Basic_Block =>
                  null;
               when DW_LNS_Const_Add_Pc =>
                  Pc := Pc + Unsigned_64
                    (Unsigned_32 ((255 - Opc_Base) / Line_Range)
                     * Unsigned_32 (Min_Insn_Len));
               when others =>
                  null;
            end case;
         else
            B := B - Opc_Base;
            Pc := Pc + Unsigned_64 (Unsigned_32 (B / Line_Range)
                                    * Unsigned_32 (Min_Insn_Len));
            Line := Line + Line_Base2 + Unsigned_32 (B mod Line_Range);
            New_Raw;
         end if;
      end loop;
      Unchecked_Deallocation (Opc_Length);
   end Read_Debug_Line;

   procedure Build_Debug_Lines
   is
      use Addresses_Containers;
      Cur_Cu : Cursor;
      Cur_Subprg : Cursor;
      Cur_Line, N_Cur_Line : Cursor;
      Cu : Addresses_Info_Acc;
      Subprg : Addresses_Info_Acc;
      Line : Addresses_Info_Acc;
      N_Line : Addresses_Info_Acc;
   begin
      --  Return now if already loaded.
      if not Addresses_Containers.Is_Empty (Lines_Set) then
         return;
      end if;

      --  Be sure compile units are loaded.
      Build_Debug_Compile_Units;

      --  Read all debug_line
      Cur_Cu := First (Compile_Units_Set);
      while Cur_Cu /= No_Element loop
         Cu := Element (Cur_Cu);
         Read_Debug_Line (Cu.Stmt_List);
         Next (Cur_Cu);
      end loop;

      --  Set .Last and parent.
      Cur_Line := First (Lines_Set);
      Cur_Subprg := First (Subprograms_Set);
      if Cur_Subprg /= No_Element then
         Subprg := Element (Cur_Subprg);
      else
         Subprg := null;
      end if;
      Cur_Cu := First (Compile_Units_Set);
      if Cur_Cu /= No_Element then
         Cu := Element (Cur_Cu);
      else
         Cu := null;
      end if;
      while Cur_Line /= No_Element loop
         Line := Element (Cur_Line);
         N_Cur_Line := Next (Cur_Line);
         if N_Cur_Line /= No_Element then
            N_Line := Element (N_Cur_Line);
         else
            N_Line := null;
         end if;

         --  Be sure Subprg and Cu are correctly set.
         while Subprg /= null and then Subprg.Last < Line.First loop
            Next (Cur_Subprg);
            if Cur_Subprg /= No_Element then
               Subprg := Element (Cur_Subprg);
            else
               Subprg := null;
            end if;
         end loop;
         while Cu /= null and then Cu.Last < Line.First loop
            Next (Cur_Cu);
            if Cur_Cu /= No_Element then
               Cu := Element (Cur_Cu);
            else
               Cu := null;
            end if;
         end loop;

         if N_Line /= null then
            --  Set Last.
            Line.Last := N_Line.First - 1;
            if Subprg /= null then
               Line.Parent := Subprg;
            end if;
         end if;
         if Subprg /= null
           and then (Line.Last > Subprg.Last or Line.Last = Line.First)
         then
            --  Truncate current line to this subprogram.
            Line.Last := Subprg.Last;
            Line.Parent := Subprg;
         end if;
         if Cu /= null
           and then (Line.Last > Cu.Last or Line.Last = Line.First)
         then
            --  Truncate current line to the CU.
            Line.Last := Cu.Last;
            Line.Parent := Cu;
         end if;

         Cur_Line := N_Cur_Line;
      end loop;
   end Build_Debug_Lines;

   procedure Build_Sections
   is
      Shdr : Elf_Shdr_Acc;
      Addr : Pc_Type;
      Last : Pc_Type;
   begin
      --  Return now if already built.
      if not Addresses_Containers.Is_Empty (Sections_Set) then
         return;
      end if;

      --  Iterate over all section headers.
      for Idx in 0 .. Get_Shdr_Num (Exe_File) - 1 loop
         Shdr := Get_Shdr (Exe_File, Idx);

         --  Only A+X sections are interesting.
         if (Shdr.Sh_Flags and (SHF_ALLOC or SHF_EXECINSTR))
           = (SHF_ALLOC or SHF_EXECINSTR)
           and then (Shdr.Sh_Type = SHT_PROGBITS)
         then
            Addr := Pc_Type (Shdr.Sh_Addr + Exe_Text_Start);
            Last := Pc_Type (Shdr.Sh_Addr + Exe_Text_Start + Shdr.Sh_Size - 1);

            Insert (Sections_Set,
                    new Addresses_Info'
                    (Kind => Section_Addresses,
                     First => Addr,
                     Last => Last,
                     Parent => null,
                     Section_Name =>
                       new String'(Get_Shdr_Name (Exe_File, Idx)),
                     Section_Index => Idx,
                     Section_Content => null));
         end if;
      end loop;
   end Build_Sections;

   procedure Load_Section_Content (Sec : Addresses_Info_Acc);

   procedure Disp_Sections_Coverage (Base : Traces_Base)
   is
      use Addresses_Containers;
      Cur : Cursor;
      Sec : Addresses_Info_Acc;
      It : Entry_Iterator;
      Trace : Trace_Entry;
      Addr : Pc_Type;

      Cur_Subprg : Cursor;
      Subprg : Addresses_Info_Acc;

      Cur_Symbol : Cursor;
      Symbol : Addresses_Info_Acc;

      Last_Addr : Pc_Type;
      State : Trace_State;
   begin
      Cur := First (Sections_Set);
      if not Is_Empty (Subprograms_Set) then
         Cur_Subprg := First (Subprograms_Set);
         Subprg := Element (Cur_Subprg);
      else
         Subprg := null;
      end if;
      if not Is_Empty (Symbols_Set) then
         Cur_Symbol := First (Symbols_Set);
         Symbol := Element (Cur_Symbol);
      else
         Symbol := null;
      end if;
      while Cur /= No_Element loop
         Sec := Element (Cur);
         Load_Section_Content (Sec);

         --  Display section name.
         Put ("Section ");
         Put (Sec.Section_Name.all);
         Put (':');
         if Sec.Section_Name'Length < 16 then
            Put ((1 .. 16 - Sec.Section_Name'Length => ' '));
         end if;
         Put (' ');
         Put (Hex_Image (Sec.First));
         Put ('-');
         Put (Hex_Image (Sec.Last));
         New_Line;

         Addr := Sec.First;
         Last_Addr := Sec.Last;
         Init (Base, It, Addr);
         Get_Next_Trace (Trace, It);

         --  Search next matching symbol.
         while Symbol /= null and then Addr > Symbol.First loop
            Next (Cur_Symbol);
            if Cur_Symbol = No_Element then
               Symbol := null;
               exit;
            end if;
            Symbol := Element (Cur_Symbol);
         end loop;

         --  Iterate on addresses range for this section.
         while Addr <= Sec.Last loop
            Last_Addr := Sec.Last;
            State := Not_Covered;

            --  Look for the next subprogram.
            while Subprg /= null and then Addr > Subprg.Last loop
               Next (Cur_Subprg);
               if Cur_Subprg = No_Element then
                  Subprg := null;
                  exit;
               end if;
               Subprg := Element (Cur_Subprg);
            end loop;
            --  Display subprogram name.
            if Subprg /= null then
               if Addr = Subprg.First then
                  New_Line;
                  Put ('<');
                  Put (Subprg.Subprogram_Name.all);
                  Put ('>');
               end if;
               if Last_Addr > Subprg.Last then
                  Last_Addr := Subprg.Last;
               end if;
            end if;

            --  Display Symbol.
            if Symbol /= null then
               if Addr = Symbol.First
                 and then (Subprg = null
                           or else (Subprg.Subprogram_Name.all
                                    /= Symbol.Symbol_Name.all))
               then
                  Put ('<');
                  Put (Symbol.Symbol_Name.all);
                  Put ('>');
                  if Subprg = null or else Subprg.First /= Addr then
                     Put (':');
                     New_Line;
                  end if;
               end if;
               while Symbol /= null and then Addr >= Symbol.First loop
                  Next (Cur_Symbol);
                  if Cur_Symbol = No_Element then
                     Symbol := null;
                     exit;
                  end if;
                  Symbol := Element (Cur_Symbol);
               end loop;
               if Symbol /= null and then Symbol.First < Last_Addr then
                  Last_Addr := Symbol.First - 1;
               end if;
            end if;

            if Subprg /= null and then Addr = Subprg.First then
               Put (':');
               New_Line;
            end if;

            if Trace /= Bad_Trace then
               if Addr >= Trace.First and Addr <= Trace.Last then
                  State := Trace.State;
               end if;
               if Addr < Trace.First and Last_Addr >= Trace.First then
                  Last_Addr := Trace.First - 1;
               elsif Last_Addr > Trace.Last then
                  Last_Addr := Trace.Last;
               end if;
            end if;

            Disassemble (Sec.Section_Content (Addr .. Last_Addr),
                         State, Textio_Disassemble_Cb'Access);

            Addr := Last_Addr;
            exit when Addr = Pc_Type'Last;
            Addr := Addr + 1;

            if Trace /= Bad_Trace and then Addr > Trace.Last then
               Get_Next_Trace (Trace, It);
            end if;
         end loop;

         Next (Cur);
      end loop;
   end Disp_Sections_Coverage;

   procedure Load_Section_Content (Sec : Addresses_Info_Acc) is
   begin
      if Sec.Section_Content = null then
         Sec.Section_Content := new Binary_Content (Sec.First .. Sec.Last);
         Load_Section (Exe_File, Sec.Section_Index,
                       Sec.Section_Content (Sec.First)'Address);
      end if;
   end Load_Section_Content;

   procedure Disp_Subprograms_Coverage (Base : Traces_Base)
   is
      use Addresses_Containers;
      use Traces_Sources;
      It : Entry_Iterator;
      Trace : Trace_Entry;
      First, Last : Pc_Type;

      Cur : Cursor;
      Sym : Addresses_Info_Acc;
      Sec : Addresses_Info_Acc;

      Subprogram_Base : Traces_Base_Acc;

      Debug : constant Boolean := False;
   begin
      if Is_Empty (Symbols_Set) then
         return;
      end if;
      Cur := Symbols_Set.First;
      while Cur /= No_Element loop
         Sym := Element (Cur);

         Sec := Sym.Parent;
         Load_Section_Content (Sec);

         declare
            subtype Rebased_Type is Binary_Content (0 .. Sym.Last - Sym.First);
         begin
            Subprogram_Base := Traces_Names.Add_Traces
              (Sym.Symbol_Name,
               Rebased_Type (Sec.Section_Content (Sym.First .. Sym.Last)));
         exception
            when others =>
               Disp_Address (Sym);
               raise;
         end;

         if Subprogram_Base /= null then
            Init (Base, It, Sym.First);
            Get_Next_Trace (Trace, It);

            if Debug then
               Put (Hex_Image (Sym.First));
               Put ('-');
               Put (Hex_Image (Sym.Last));
               Put (": ");
               Put (Sym.Symbol_Name.all);
               New_Line;
            end if;

            while Trace /= Bad_Trace loop
               exit when Trace.First > Sym.Last;
               if Debug then
                  Dump_Entry (Trace);
               end if;
               if Trace.Last >= Sym.First then
                  if Trace.First > Sym.First then
                     First := Trace.First - Sym.First;
                  else
                     First := 0;
                  end if;
                  Last := Trace.Last - Sym.First;
                  if Last > Sym.Last - Sym.First then
                     Last := Sym.Last - Sym.First;
                  end if;
                  if Debug then
                     Put (Hex_Image (First));
                     Put ('-');
                     Put (Hex_Image (Last));
                     Put (": ");
                     Dump_Op (Trace.Op);
                     New_Line;
                  end if;
                  Add_Entry (Subprogram_Base.all, First, Last, Trace.Op);
               end if;

               Get_Next_Trace (Trace, It);
            end loop;
         end if;

         Next (Cur);
      end loop;
   end Disp_Subprograms_Coverage;

   procedure Build_Source_Lines (Base : in out Traces_Base)
   is
      use Addresses_Containers;
      use Traces_Sources;
      Cur : Cursor;
      Line : Addresses_Info_Acc;
      Prev_File : Source_File;
      Prev_Filename : String_Acc := null;

      It : Entry_Iterator;
      E : Trace_Entry;
      Pc : Pc_Type;
      No_Traces : Boolean;

      Debug : constant Boolean := False;
   begin
      Init (Base, It, 0);
      Get_Next_Trace (E, It);
      No_Traces := E = Bad_Trace;

      --  Iterate on lines.
      Cur := First (Lines_Set);
      while Cur /= No_Element loop
         Line := Element (Cur);

         --  Get corresponding file (check previous file for speed-up).
         if Line.Line_Filename /= Prev_Filename then
            Prev_File := Find_File (Line.Line_Filename);
            Prev_Filename := Line.Line_Filename;
         end if;

         Add_Line (Prev_File, Line.Line_Number, Line);

         --  Skip not-matching traces.
         while not No_Traces and then E.Last < Line.First loop
            --  There is no source line for this entry.
            Get_Next_Trace (E, It);
            No_Traces := E = Bad_Trace;
         end loop;

         if Debug then
            New_Line;
            Disp_Address (Line);
         end if;

         Pc := Line.First;
         loop
            --  From PC to E.First
            if No_Traces or else Pc < E.First then
               if Debug then
                  Put_Line ("no trace for pc=" & Hex_Image (Pc));
               end if;
               Add_Line_State (Prev_File, Line.Line_Number, Not_Covered);
            end if;

            exit when No_Traces or else E.First > Line.Last;

            if Debug then
               Put_Line ("merge with:");
               Dump_Entry (E);
            end if;

            --  From E.First to min (E.Last, line.last)
            Add_Line_State (Prev_File, Line.Line_Number, E.State);

            exit when E.Last >= Line.Last;
            Pc := E.Last + 1;
            Get_Next_Trace (E, It);
            No_Traces := E = Bad_Trace;
         end loop;

         Next (Cur);
      end loop;
   end Build_Source_Lines;

   procedure Set_Trace_State (Base : in out Traces_Base;
                              Section : Binary_Content)
   is
      use Addresses_Containers;

      It : Entry_Iterator;
      Trace : Trace_Entry;
      Addr : Pc_Type;
   begin
      Addr := Section'First;
      Init (Base, It, Addr);
      Get_Next_Trace (Trace, It);

      while Trace /= Bad_Trace loop
         exit when Addr > Section'Last;
         exit when Trace.First > Section'Last;

         case Exe_Machine is
            when EM_PPC =>
               declare
                  Insn : Binary_Content (0 .. 3);
                  Op : constant Unsigned_8 := Trace.Op and 3;
                  Trace_Len : constant Pc_Type :=
                    Trace.Last - Trace.First + 1;

                  procedure Update_Or_Split (Next_State : Trace_State)
                  is
                  begin
                     if Trace_Len = 4 then
                        Update_State (Base, It, Next_State);
                     else
                        Split_Trace (Base, It, Trace.Last - 4,
                                     Covered, Next_State);
                     end if;
                  end Update_Or_Split;
               begin
                  --  Instructions length is 4.
                  if Trace_Len < 4 then
                     raise Program_Error;
                  end if;
                  case Op is
                     when 0 =>
                        Update_State (Base, It, Covered);
                     when 1 =>
                        for I in Unsigned_32 range 0 .. 3 loop
                           Insn (I) := Section (Trace.Last - 3 + I);
                        end loop;
                        if (Insn (0) and 16#Fc#) = 16#48# then
                           --  Opc = 18: b, ba, bl and bla
                           Update_State (Base, It, Covered);
                        elsif ((Insn (0) and 16#Fe#) = 16#42#
                                 or else (Insn (0) and 16#Fe#) = 16#4e#)
                          and then (Insn (1) and 16#80#) = 16#80#
                        then
                           --  Opc = 16 (bcx) or Opc = 19 (bcctrx)
                           --   BO = 1x1xx
                           --  bc/bcctr always
                           Update_State (Base, It, Covered);
                        else
                           Update_Or_Split (Branch_Taken);
                        end if;
                     when 2 =>
                        Update_Or_Split (Fallthrough_Taken);
                     when 3 =>
                        Update_Or_Split (Both_Taken);
                     when others =>
                        raise Program_Error;
                  end case;
               end;
            when others =>
               exit;
         end case;

         Addr := Trace.Last;
         exit when Addr = Pc_Type'Last;
         Addr := Addr + 1;
         Get_Next_Trace (Trace, It);
      end loop;
   end Set_Trace_State;

   procedure Set_Trace_State (Base : in out Traces_Base)
   is
      use Addresses_Containers;
      Cur : Cursor;
      Sec : Addresses_Info_Acc;

   begin
      Cur := First (Sections_Set);
      while Cur /= No_Element loop
         Sec := Element (Cur);

         Load_Section_Content (Sec);

         Set_Trace_State (Base, Sec.Section_Content.all);
         --  Unchecked_Deallocation (Section);

         Next (Cur);
      end loop;
   end Set_Trace_State;

   procedure Build_Symbols
   is
      use Addresses_Containers;

      type Addr_Info_Acc_Arr is array (0 .. Get_Shdr_Num (Exe_File))
        of Addresses_Info_Acc;
      Sections_Info : Addr_Info_Acc_Arr := (others => null);
      Sec : Addresses_Info_Acc;

      Symtab_Idx : Elf_Half;
      Symtab_Shdr : Elf_Shdr_Acc;
      Symtab_Len : Elf_Size;
      Symtabs : Binary_Content_Acc;

      Strtab_Idx : Elf_Half;
      Strtab_Len : Elf_Size;
      Strtabs : Binary_Content_Acc;
      Sym : Elf_Sym;

      Sym_Type : Unsigned_8;
      Cur : Cursor;
      Ok : Boolean;
   begin
      --  Build_Sections must be called before.
      if Sections_Set.Is_Empty then
         raise Program_Error;
      end if;

      if not Symbols_Set.Is_Empty then
         return;
      end if;

      Cur := First (Sections_Set);
      while Has_Element (Cur) loop
         Sec := Element (Cur);
         Sections_Info (Sec.Section_Index) := Sec;
         Next (Cur);
      end loop;

      Symtab_Idx := Get_Shdr_By_Name (Exe_File, ".symtab");
      if Symtab_Idx = SHN_UNDEF then
         return;
      end if;
      Symtab_Shdr := Get_Shdr (Exe_File, Symtab_Idx);
      if Symtab_Shdr.Sh_Type /= SHT_SYMTAB
        or else Symtab_Shdr.Sh_Link = 0
        or else Natural (Symtab_Shdr.Sh_Entsize) /= Elf_Sym_Size
      then
         return;
      end if;
      Strtab_Idx := Elf_Half (Symtab_Shdr.Sh_Link);

      Symtab_Len := Get_Section_Length (Exe_File, Symtab_Idx);
      Symtabs := new Binary_Content (0 .. Symtab_Len - 1);
      Load_Section (Exe_File, Symtab_Idx, Symtabs (0)'Address);

      Strtab_Len := Get_Section_Length (Exe_File, Strtab_Idx);
      Strtabs := new Binary_Content (0 .. Strtab_Len - 1);
      Load_Section (Exe_File, Strtab_Idx, Strtabs (0)'Address);

      for I in 1 .. Natural (Symtab_Len) / Elf_Sym_Size loop
         Sym := Get_Sym
           (Exe_File,
            Symtabs (0)'Address + Storage_Offset ((I - 1) * Elf_Sym_Size));
         Sym_Type := Elf_St_Type (Sym.St_Info);
         if  (Sym_Type = STT_FUNC or Sym_Type = STT_NOTYPE)
           and then Sym.St_Shndx in Sections_Info'Range
           and then Sections_Info (Sym.St_Shndx) /= null
           and then Sym.St_Size > 0
         then
            Addresses_Containers.Insert
              (Symbols_Set,
               new Addresses_Info'
               (Kind => Symbol_Addresses,
                First => Exe_Text_Start + Pc_Type (Sym.St_Value),
                Last => Exe_Text_Start + Pc_Type (Sym.St_Value
                                                  + Sym.St_Size - 1),
                Parent => Sections_Info (Sym.St_Shndx),
                Symbol_Name => new String'
                (Read_String (Strtabs (Sym.St_Name)'Address))),
               Cur, Ok);
         end if;
      end loop;
      Unchecked_Deallocation (Strtabs);
      Unchecked_Deallocation (Symtabs);
   end Build_Symbols;

   Last_Section : Addresses_Info_Acc;

   function Get_Section_By_Addr (Pc : Pc_Type) return Addresses_Info_Acc
   is
   begin
      --  Search if not in the last section.
      if Last_Section = null
        or else (Pc not in Last_Section.First .. Last_Section.Last)
      then
         --  FIXME: use container primitives.
         declare
            use Addresses_Containers;
            Cur : Cursor;
            Sec : Addresses_Info_Acc;
         begin
            Last_Section := null;
            Cur := First (Sections_Set);
            loop
               if Cur = No_Element then
                  raise Program_Error;
               end if;
               Sec := Element (Cur);
               if Pc in Sec.First .. Sec.Last then
                  Last_Section := Sec;
                  exit;
               end if;
               Next (Cur);
            end loop;
         end;
      end if;

      return Last_Section;
   end Get_Section_By_Addr;

--     function Get_Section_Addr (Pc : Pc_Type) return Address
--     is
--        Res : Addresses_Info_Acc;
--     begin
--        Res := Get_Section_By_Addr (Pc);
--        if Res /= null then
--           return Res.Section_Content (Pc)'Address;
--        else
--           return Null_Address;
--        end if;
--     end Get_Section_Addr;

   Get_Symbol_Sym : constant Addresses_Info_Acc :=
     new Addresses_Info (Symbol_Addresses);

   procedure Get_Symbol (Pc : Pc_Type;
                         Line : in out String;
                         Line_Pos : in out Natural)
   is
      use Addresses_Containers;
      Cur : Cursor;
      Sym : Addresses_Info_Acc;

      procedure Add (C : Character) is
      begin
         if Line_Pos <= Line'Last then
            Line (Line_Pos) := C;
            Line_Pos := Line_Pos + 1;
         end if;
      end Add;

      --  Add STR to the line.
      procedure Add (Str : String) is
      begin
         for I in Str'Range loop
            Add (Str (I));
         end loop;
      end Add;

   begin
      Get_Symbol_Sym.First := Pc;
      Get_Symbol_Sym.Last := Pc;
      Cur := Floor (Symbols_Set, Get_Symbol_Sym);
      if Cur = No_Element then
         return;
      end if;
      Sym := Element (Cur);
      if Pc > Sym.Last then
         return;
      end if;

      Add (" <");
      Add (Sym.Symbol_Name.all);
      if Pc /= Sym.First then
         Add ('+');
         Add (Hex_Image (Pc - Sym.First));
      end if;
      Add ('>');
   end Get_Symbol;

   --  INSN is exactly one instruction.
   --  Generate the disassembly for INSN.
   function Disassemble (Insn : Binary_Content; Pc : Pc_Type) return String
   is
      Addr : Address;
      Line_Pos : Natural;
      Line : String (1 .. 128);
      Insn_Len : Natural := 0;
   begin
      Addr := Insn (Insn'First)'Address;
      Disa_Ppc.Disassemble_Insn
        (Addr, Pc, Line, Line_Pos, Insn_Len, Get_Symbol'Access);
      if Insn_Len /= Insn'Length then
         raise Constraint_Error;
      end if;
      return Line (1 .. Line_Pos - 1);
   end Disassemble;

   procedure Textio_Disassemble_Cb (Addr : Pc_Type;
                                    State : Trace_State;
                                    Insn : Binary_Content)
   is
   begin
      Put (Hex_Image (Addr));
      Put (' ');
      Disp_State_Char (State);
      Put (":");
      Put (ASCII.HT);
      for I in Insn'Range loop
         Put (Hex_Image (Insn (I)));
         Put (' ');
      end loop;
      Put ("  ");
      Put (Disassemble (Insn, Addr));
      New_Line;
   end Textio_Disassemble_Cb;

   procedure Disassemble (Insns : Binary_Content;
                          State : Trace_State;
                          Cb : Disassemble_Cb)
   is
      type Binary_Content_Thin_Acc is access Binary_Content (Elf_Size);
      function To_Binary_Content_Thin_Acc is new Ada.Unchecked_Conversion
        (Address, Binary_Content_Thin_Acc);
      Pc : Pc_Type;
      Addr : Address;
      Insn_Len : Natural := 0;
   begin
      Pc := Insns'First;
      while Pc < Insns'Last loop
         Addr := Insns (Pc)'Address;
         Insn_Len := Disa_Ppc.Get_Insn_Length (Addr);
         Cb.all
           (Pc, State,
            To_Binary_Content_Thin_Acc (Addr)(0 .. Elf_Size (Insn_Len) - 1));
         Pc := Pc + Pc_Type (Insn_Len);
         exit when Pc = 0;
      end loop;
   end Disassemble;

   function Get_Label (Info : Addresses_Info_Acc) return String
   is
      Line : String (1 .. 64);
      Line_Pos : Natural;
   begin
      --  Display address.
      Line_Pos := Line'First;
      Get_Symbol (Info.First, Line, Line_Pos);
      if Line_Pos > Line'First then
         if Line_Pos > Line'Last then
            Line_Pos := Line'Last;
         end if;
         Line (Line_Pos) := ':';
         return Line (Line'First + 1 .. Line_Pos);
      else
         return "";
      end if;
   end Get_Label;

   procedure Disp_Assembly_Lines
     (Insns : Binary_Content;
      Base : Traces_Base;
      Cb : access procedure (Addr : Pc_Type;
                             State : Trace_State;
                             Insn : Binary_Content))
   is
      It : Entry_Iterator;
      E : Trace_Entry;
      Addr : Pc_Type;
      Next_Addr : Pc_Type;
      State : Trace_State;
   begin
      --  Disp_Address (Info);
      Init (Base, It, Insns'First);
      Get_Next_Trace (E, It);
      Addr := Insns'First;

      loop
         Next_Addr := Insns'Last;

         --  Find matching trace.
         while E /= Bad_Trace and then Addr > E.Last loop
            Get_Next_Trace (E, It);
         end loop;
         --  Dump_Entry (E);
         if E /= Bad_Trace and then (Addr >= E.First and Addr <= E.Last) then
            State := E.State;
            if E.Last < Next_Addr then
               Next_Addr := E.Last;
            end if;
         else
            State := Not_Covered;
            if E /= Bad_Trace and then E.First < Next_Addr then
               Next_Addr := E.First - 1;
            end if;
         end if;
         Disassemble (Insns (Addr .. Next_Addr), State, Cb);
         exit when Next_Addr >= Insns'Last;
         Addr := Next_Addr + 1;
      end loop;
   end Disp_Assembly_Lines;

   procedure Build_Routine_Names is
   begin
      Traces_Names.Read_Routines_Name
        (Exe_File, new String'(Get_Filename (Exe_File)), False);
   end Build_Routine_Names;
end Traces_Elf;
