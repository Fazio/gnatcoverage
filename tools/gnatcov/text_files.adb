------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2019-2020, AdaCore                     --
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

with GNAT.OS_Lib;

with Outputs;

package body Text_Files is

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Self : File_Type) return Boolean is
   begin
      return Is_Open (Self.File);
   end Is_Open;

   ----------
   -- Mode --
   ----------

   function Mode (Self : File_Type) return File_Mode is
   begin
      return Mode (Self.File);
   end Mode;

   ----------
   -- Open --
   ----------

   function Open
     (Self : in out File_Type;
      Name : String;
      Mode : File_Mode := Ada.Text_IO.In_File)
      return Boolean is
   begin
      Open (Self.File, Mode, Name);
      Self.Filename := US.To_Unbounded_String (Name);
      return True;
   exception
      when Use_Error | Name_Error =>
         return False;
   end Open;

   ------------
   -- Create --
   ------------

   function Create
     (Self : in out File_Type;
      Name : String;
      Mode : File_Mode := Ada.Text_IO.Out_File)
      return Boolean is
   begin
      Create (Self.File, Mode, Name);
      Self.Filename := US.To_Unbounded_String (Name);
      return True;
   exception
      when Use_Error | Name_Error =>
         return False;
   end Create;

   ----------
   -- Open --
   ----------

   procedure Open
     (Self : in out File_Type;
      Name : String;
      Mode : File_Mode := Ada.Text_IO.In_File) is
   begin
      if not Self.Open (Name, Mode) then
         Outputs.Fatal_Error ("cannot open " & Name);
      end if;
   end Open;

   ------------
   -- Create --
   ------------

   procedure Create
     (Self : in out File_Type;
      Name : String;
      Mode : File_Mode := Ada.Text_IO.Out_File) is
   begin
      if not Self.Create (Name, Mode) then
         Outputs.Fatal_Error ("cannot open " & Name);
      end if;
   end Create;

   ---------
   -- Put --
   ---------

   procedure Put (Self : in out File_Type; Item : String) is
   begin
      Put (Self.File, Item);
   end Put;

   --------------
   -- Put_Line --
   --------------

   procedure Put_Line (Self : in out File_Type; Item : String) is
   begin
      Put_Line (Self.File, Item);
   end Put_Line;

   --------------
   -- New_Line --
   --------------

   procedure New_Line (Self : in out File_Type) is
   begin
      New_Line (Self.File);
   end New_Line;

   -----------
   -- Close --
   -----------

   procedure Close (Self : in out File_Type) is
   begin
      Close (Self.File);
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out File_Type) is
   begin
      if Self.Is_Open then
         Close (Self.File);
      end if;
   end Finalize;

   ----------------
   -- Run_GNATpp --
   ----------------

   procedure Run_GNATpp (Self : Text_Files.File_Type) is
      use GNAT.OS_Lib;

      Filename : constant String := US.To_String (Self.Filename);
      Args     : constant Argument_List := (1 => Filename'Unrestricted_Access);
      GNATpp   : String_Access := Locate_Exec_On_Path ("gnatpp");
      Success  : Boolean;
   begin
      if GNATpp = null then
         Put_Line ("gnatpp not available");
         return;
      end if;
      Spawn (GNATpp.all, Args, Success);
      Free (GNATpp);
      if not Success then
         Put_Line ("pretty-printing " & Filename & " failed!");
      end if;
   end Run_GNATpp;

end Text_Files;
