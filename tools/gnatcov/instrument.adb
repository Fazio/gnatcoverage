------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2008-2018, AdaCore                     --
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

--  Source instrumentation

with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with GNATCOLL.Projects;
with GNATCOLL.VFS;

with Project;
with SC_Obligations;
with Strings;
with Switches;
with Text_Files;

with Instrument.Common;  use Instrument.Common;
with Instrument.Sources; use Instrument.Sources;

package body Instrument is

   procedure Prepare_Output_Dirs (IC : Inst_Context);
   --  Make sure we have the expected tree of directories for the
   --  instrumentation output.

   procedure Emit_Buffer_Unit (IC : Inst_Context; UIC : Unit_Inst_Context);
   --  Emit the unit to contain coverage buffers for the given instrumented
   --  unit.

   procedure Emit_Closure_Unit (IC : Inst_Context);
   --  Emit a generic procedure to output coverage buffers for all units of
   --  interest.

   procedure Emit_Project_Files (IC : Inst_Context);
   --  Emit project files to cover the instrumented sources

   -------------------------
   -- Prepare_Output_Dirs --
   -------------------------

   procedure Prepare_Output_Dirs (IC : Inst_Context) is
   begin
      --  TODO??? Preserve existing files/directories but remove extra
      --  files, for instance when users re-instrument a project with one
      --  unit that was removed since the previous run.

      if Ada.Directories.Exists (+IC.Output_Dir) then
         Ada.Directories.Delete_Tree (+IC.Output_Dir);
      end if;

      Ada.Directories.Create_Path (+IC.Output_Dir);
      Ada.Directories.Create_Path (+IC.Instr_Dir);
      Ada.Directories.Create_Path (+IC.Buffers_Dir);
   end Prepare_Output_Dirs;

   ----------------------
   -- Emit_Buffer_Unit --
   ----------------------

   procedure Emit_Buffer_Unit (IC : Inst_Context; UIC : Unit_Inst_Context) is
      CU_Name : Compilation_Unit_Name renames UIC.Buffer_Unit;
      File    : Text_Files.File_Type;
   begin
      File.Create ((+IC.Buffers_Dir) / To_Filename (CU_Name));

      declare
         Pkg_Name : constant String := To_Ada (CU_Name.Unit);

         Closure_Hash : constant String := Strings.Img (0);
         --  TODO??? Actually compute this hash

         Unit_Name : constant String := Ada.Characters.Handling.To_Lower
           (To_Ada (UIC.Instrumented_Unit.Unit));
         Unit_Kind : constant String :=
           (case UIC.Instrumented_Unit.Kind is
            when Unit_Spec => "Unit_Spec",
            when Unit_Body => "Unit_Body");
      begin
         File.Put_Line ("package " & Pkg_Name & " is");
         File.New_Line;
         File.Put_Line ("   Buffers : Unit_Coverage_Buffers :=");
         File.Put_Line ("     (Unit_Name_Length => "
                        & Strings.Img (Unit_Name'Length) & ",");
         File.Put_Line ("      Stmt_Last_Bit => "
                        & Img (UIC.Unit_Bits.Last_Statement_Bit) & ",");
         File.Put_Line ("      Dc_Last_Bit => "
                        & Img (UIC.Unit_Bits.Last_Decision_Bit) & ",");
         File.Put_Line ("      Closure_Hash => " & Closure_Hash & ",");
         File.Put_Line ("      Unit_Kind => " & Unit_Kind & ",");
         File.Put_Line ("      Unit_Name => """ & Unit_Name & """,");
         File.Put_Line ("      others => <>);");
         File.New_Line;
         File.Put_Line ("end " & Pkg_Name & ";");
      end;
   end Emit_Buffer_Unit;

   -----------------------
   -- Emit_Closure_Unit --
   -----------------------

   procedure Emit_Closure_Unit (IC : Inst_Context) is
      Project_Name : constant String := Ada.Directories.Base_Name
        (Project.Root_Project_Filename);
      --  TODO??? Get the original casing for the project name

      CU_Name : Compilation_Unit_Name := (Sys_Closures, Unit_Spec);
      File    : Text_Files.File_Type;

      package Buffer_Vectors is new Ada.Containers.Vectors
        (Positive, Unbounded_String);

      Buffer_Units : Buffer_Vectors.Vector;
   begin
      CU_Name.Unit.Append (To_Unbounded_String (Project_Name));

      --  Compute the list of units that contain the coverage buffers to
      --  process.

      for Cur in IC.Instrumented_Units.Iterate loop
         declare
            I_Unit : constant Compilation_Unit_Name :=
               Instrumented_Unit_Maps.Key (Cur);
            B_Unit : constant String := To_Ada (Buffer_Unit (I_Unit));
         begin
            Buffer_Units.Append (+B_Unit);
         end;
      end loop;

      --  Now emit the generic procedure

      declare
         Unit_Name : constant String := To_Ada (CU_Name.Unit);
      begin
         File.Create ((+IC.Buffers_Dir) / To_Filename (CU_Name));
         File.Put_Line ("generic");
         File.Put_Line ("  with procedure Process"
                        & " (Buffers : Unit_Coverage_Buffers);");
         File.Put_Line ("procedure " & Unit_Name & ";");
         File.New_Line;
         File.Close;

         CU_Name.Kind := Unit_Body;
         File.Create ((+IC.Buffers_Dir) / To_Filename (CU_Name));
         for Unit of Buffer_Units loop
            File.Put_Line ("with " & To_String (Unit) & ";");
         end loop;
         File.New_Line;
         File.Put_Line ("procedure " & Unit_Name & " is");
         File.Put_Line ("begin");
         for Unit of Buffer_Units loop
            File.Put_Line
              ("   Process (" & To_String (Unit) & ".Buffers);");
         end loop;
         File.Put_Line ("end " & Unit_Name & ";");
         File.New_Line;
      end;
   end Emit_Closure_Unit;

   ------------------------
   -- Emit_Project_Files --
   ------------------------

   procedure Emit_Project_Files (IC : Inst_Context) is
      File : Text_Files.File_Type;
   begin
      File.Create ((+IC.Output_Dir) / "instrumented.gpr");
      File.Put_Line ("with ""buffers.gpr"";");
      File.Put_Line ("project Instrumented extends """
                     & Project.Root_Project_Filename & """ is");
      File.Put_Line ("   for Source_Dirs use (""src-instr"");");
      File.Put_Line ("   for Object_Dir use ""obj-instr"";");
      File.Put_Line ("end Instrumented;");
      File.Close;

      File.Create ((+IC.Output_Dir) / "buffers.gpr");
      File.Put_Line ("project Buffers");
      File.Put_Line ("   extends ""gnatcoverage/gnatcov_rts.gpr""");
      File.Put_Line ("is");
      File.Put_Line ("   for Source_Dirs use (""src-buffers"");");
      File.Put_Line ("   for Object_Dir use ""obj-buffers"";");
      File.Put_Line ("end Buffers;");
   end Emit_Project_Files;

   ----------------------------------
   -- Instrument_Units_Of_Interest --
   ----------------------------------

   procedure Instrument_Units_Of_Interest (Units_Inputs : Inputs.Inputs_Type)
   is
      IC : Inst_Context := Create_Context;

      procedure Add_Instrumented_Unit
        (Source_File : GNATCOLL.Projects.File_Info);
      --  Add the given source file to IC.Instrumented_Units

      ---------------------------
      -- Add_Instrumented_Unit --
      ---------------------------

      procedure Add_Instrumented_Unit
        (Source_File : GNATCOLL.Projects.File_Info)
      is
         use GNATCOLL.VFS;
      begin
         IC.Instrumented_Units.Insert (To_Compilation_Unit_Name (Source_File),
                                       +Source_File.File.Full_Name);
      end Add_Instrumented_Unit;

   --  Start of processing for Instrument_Units_Of_Interest

   begin
      --  First collect the list of all units to instrument

      Project.Enumerate_Ada_Sources
        (Add_Instrumented_Unit'Access, Units_Inputs);

      --  Then run the instrumentation process itself

      Prepare_Output_Dirs (IC);
      for Cur in IC.Instrumented_Units.Iterate loop
         declare
            UIC : Unit_Inst_Context;
         begin
            Instrument_Unit (Instrumented_Unit_Maps.Key (Cur),
                             Instrumented_Unit_Maps.Element (Cur),
                             IC, UIC);
            Emit_Buffer_Unit (IC, UIC);
         end;
      end loop;
      Emit_Closure_Unit (IC);
      Emit_Project_Files (IC);

      if Switches.Verbose then
         SC_Obligations.Dump_All_SCOs;
      end if;
   end Instrument_Units_Of_Interest;

end Instrument;
