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
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with GNATCOLL.Projects;
with GNATCOLL.VFS;

with Libadalang.Common;
with Libadalang.Rewriting;

with Checkpoints;
with Coverage;
with Diagnostics;        use Diagnostics;
with Instrument.Common;  use Instrument.Common;
with Instrument.Sources; use Instrument.Sources;
with Project;
with SC_Obligations;
with Strings;
with Switches;
with Text_Files;

package body Instrument is

   procedure Prepare_Output_Dirs (IC : Inst_Context);
   --  Make sure we have the expected tree of directories for the
   --  instrumentation output.

   procedure Emit_Buffer_Unit
     (Info : in out Project_Info; UIC : Unit_Inst_Context);
   --  Emit the unit to contain coverage buffers for the given instrumented
   --  unit.

   procedure Emit_Pure_Buffer_Unit
     (Info : in out Project_Info; UIC : Unit_Inst_Context);
   --  Emit the unit to contain addresses for the coverage buffers

   procedure Emit_Buffers_List_Unit
     (IC                : in out Inst_Context;
      Root_Project_Info : in out Project_Info);
   --  Emit in the root project a unit to contain the list of coverage buffers
   --  for all units of interest.

   procedure Auto_Dump_Buffers_In_Ada_Mains (IC : in out Inst_Context);
   --  Instrument source files for Ada mains that are not units of interest to
   --  add a dump of coverage buffers.

   procedure Remove_Old_Instr_Files (IC : Inst_Context);
   --  Remove sources in output directories that were not generated during this
   --  instrumentation process.

   -------------------------
   -- Prepare_Output_Dirs --
   -------------------------

   procedure Prepare_Output_Dirs (IC : Inst_Context) is
      use Project_Info_Maps;
   begin
      for Cur in IC.Project_Info_Map.Iterate loop
         declare
            Output_Dir : constant String :=
               +(Element (Cur).Output_Dir);
         begin
            if not Ada.Directories.Exists (Output_Dir) then
               Ada.Directories.Create_Path (Output_Dir);
            end if;
         end;
      end loop;
   end Prepare_Output_Dirs;

   ----------------------
   -- Emit_Buffer_Unit --
   ----------------------

   procedure Emit_Buffer_Unit
     (Info : in out Project_Info; UIC : Unit_Inst_Context)
   is
      CU_Name : Compilation_Unit_Name renames UIC.Buffer_Unit;
      File    : Text_Files.File_Type;
   begin
      Create_File (Info, File, To_Filename (CU_Name));

      declare
         Pkg_Name : constant String := To_Ada (CU_Name.Unit);

         Fingerprint : Unbounded_String;

         Unit_Name : constant String := Ada.Characters.Handling.To_Lower
           (To_Ada (UIC.Instrumented_Unit.Unit));

         Unit_Part : constant String :=
           (case UIC.Instrumented_Unit.Part is
            when GNATCOLL.Projects.Unit_Spec     => "Unit_Spec",
            when GNATCOLL.Projects.Unit_Body     => "Unit_Body",
            when GNATCOLL.Projects.Unit_Separate => "Unit_Separate");
         --  Do not use 'Image so that we use the original casing for the
         --  enumerators, and thus avoid compilation warnings/errors.

         Statement_Last_Bit : constant String := Img
           (UIC.Unit_Bits.Last_Statement_Bit);
         Decision_Last_Bit  : constant String := Img
           (UIC.Unit_Bits.Last_Outcome_Bit);
         MCDC_Last_Bit      : constant String := Img
           (UIC.Unit_Bits.Last_Path_Bit);

      begin
         --  Turn the fingerprint value into the corresponding Ada literal

         declare
            First : Boolean := True;
         begin
            Append (Fingerprint, "(");
            for Byte of SC_Obligations.Fingerprint (UIC.CU) loop
               if First then
                  First := False;
               else
                  Append (Fingerprint, ", ");
               end if;
               Append (Fingerprint, Strings.Img (Integer (Byte)));
            end loop;
            Append (Fingerprint, ")");
         end;

         File.Put_Line ("package " & Pkg_Name & " is");
         File.New_Line;
         File.Put_Line ("   pragma Preelaborate;");
         File.New_Line;
         File.Put_Line ("   Statement_Buffer : Coverage_Buffer_Type"
                        & " (0 .. " & Statement_Last_Bit & ") :="
                        & " (others => False);");
         File.Put_Line ("   Statement_Buffer_Address : constant System.Address"
                        & " := Statement_Buffer'Address;");
         File.Put_Line ("   pragma Export (Ada, Statement_Buffer_Address, """
                        & Statement_Buffer_Symbol (UIC.Instrumented_Unit)
                        & """);");
         File.New_Line;

         File.Put_Line ("   Decision_Buffer : Coverage_Buffer_Type"
                        & " (0 .. " & Decision_Last_Bit & ") :="
                        & " (others => False);");
         File.Put_Line ("   Decision_Buffer_Address : constant System.Address"
                        & " := Decision_Buffer'Address;");
         File.Put_Line ("   pragma Export (Ada, Decision_Buffer_Address, """
                        & Decision_Buffer_Symbol (UIC.Instrumented_Unit)
                        & """);");
         File.New_Line;

         File.Put_Line ("   MCDC_Buffer : Coverage_Buffer_Type"
                        & " (0 .. " & MCDC_Last_Bit & ") :="
                        & " (others => False);");
         File.Put_Line ("   MCDC_Buffer_Address : constant System.Address"
                        & " := MCDC_Buffer'Address;");
         File.Put_Line ("   pragma Export (Ada, MCDC_Buffer_Address, """
                        & MCDC_Buffer_Symbol (UIC.Instrumented_Unit)
                        & """);");
         File.New_Line;

         File.Put_Line ("   Buffers : aliased Unit_Coverage_Buffers :=");
         File.Put_Line ("     (Unit_Name_Length => "
                        & Strings.Img (Unit_Name'Length) & ",");
         File.Put_Line ("      Fingerprint => "
                        & To_String (Fingerprint) & ",");

         File.Put_Line ("      Unit_Part => " & Unit_Part & ",");
         File.Put_Line ("      Unit_Name => """ & Unit_Name & """,");

         File.Put_Line ("      Statement => Statement_Buffer'Address,");
         File.Put_Line ("      Decision  => Decision_Buffer'Address,");
         File.Put_Line ("      MCDC      => MCDC_Buffer'Address,");

         File.Put_Line ("      Statement_Last_Bit => " & Statement_Last_Bit
                        & ",");
         File.Put_Line ("      Decision_Last_Bit => " & Decision_Last_Bit
                        & ",");
         File.Put_Line ("      MCDC_Last_Bit => " & MCDC_Last_Bit & ");");
         File.New_Line;
         File.Put_Line ("end " & Pkg_Name & ";");
      end;
   end Emit_Buffer_Unit;

   ---------------------------
   -- Emit_Pure_Buffer_Unit --
   ---------------------------

   procedure Emit_Pure_Buffer_Unit
     (Info : in out Project_Info; UIC : Unit_Inst_Context)
   is
      CU_Name : Compilation_Unit_Name renames UIC.Pure_Buffer_Unit;
      File    : Text_Files.File_Type;
   begin
      Create_File (Info, File, To_Filename (CU_Name));

      declare
         Pkg_Name : constant String := To_Ada (CU_Name.Unit);
      begin
         File.Put_Line ("with System;");
         File.New_Line;
         File.Put_Line ("package " & Pkg_Name & " is");
         File.New_Line;
         File.Put_Line ("   pragma Pure;");
         File.New_Line;
         File.Put_Line ("   Statement_Buffer : constant System.Address;");
         File.Put_Line ("   pragma Import (Ada, Statement_Buffer, """
                        & Statement_Buffer_Symbol (UIC.Instrumented_Unit)
                        & """);");
         File.New_Line;
         File.Put_Line ("   Decision_Buffer : constant System.Address;");
         File.Put_Line ("   pragma Import (Ada, Decision_Buffer, """
                        & Decision_Buffer_Symbol (UIC.Instrumented_Unit)
                        & """);");
         File.New_Line;
         File.Put_Line ("   MCDC_Buffer : constant System.Address;");
         File.Put_Line ("   pragma Import (Ada, MCDC_Buffer, """
                        & MCDC_Buffer_Symbol (UIC.Instrumented_Unit)
                        & """);");
         File.New_Line;
         File.Put_Line ("end " & Pkg_Name & ";");
      end;
   end Emit_Pure_Buffer_Unit;

   ----------------------------
   -- Emit_Buffers_List_Unit --
   ----------------------------

   procedure Emit_Buffers_List_Unit
     (IC                : in out Inst_Context;
      Root_Project_Info : in out Project_Info)
   is
      use GNATCOLL.Projects;

      CU_Name : Compilation_Unit_Name := (Sys_Buffers_Lists, Unit_Spec);
      File    : Text_Files.File_Type;

      package Buffer_Vectors is new Ada.Containers.Vectors
        (Positive, Unbounded_String);

      Buffer_Units : Buffer_Vectors.Vector;
   begin
      CU_Name.Unit.Append (Ada_Identifier (IC.Project_Name));

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

      --  Now emit the unit to contain the list of buffers

      declare
         use type Ada.Containers.Count_Type;

         Unit_Name : constant String := To_Ada (CU_Name.Unit);
         First     : Boolean := True;
      begin
         Create_File (Root_Project_Info, File, To_Filename (CU_Name));
         for Unit of Buffer_Units loop
            File.Put_Line ("with " & To_String (Unit) & ";");
         end loop;
         File.New_Line;
         File.Put_Line ("package " & Unit_Name & " is");
         File.New_Line;
         File.Put_Line ("   List : constant Unit_Coverage_Buffers_Array"
                        & " :=");
         File.Put ("     (");
         if Buffer_Units.Length = 1 then
            File.Put ("1 => ");
         end if;
         for Unit of Buffer_Units loop
            if First then
               First := False;
            else
               File.Put_Line (",");
               File.Put ((1 .. 6 => ' '));
            end if;
            File.Put (To_String (Unit) & ".Buffers'Access");
         end loop;
         File.Put_Line (");");
         File.New_Line;
         File.Put_Line ("end " & Unit_Name & ";");
      end;
   end Emit_Buffers_List_Unit;

   ------------------------------------
   -- Auto_Dump_Buffers_In_Ada_Mains --
   ------------------------------------

   procedure Auto_Dump_Buffers_In_Ada_Mains (IC : in out Inst_Context) is
   begin
      for Main of IC.Main_To_Instrument_Vector loop
         declare
            use type GNATCOLL.VFS.Filesystem_String;

            Rewriter : Source_Rewriter;
         begin
            Rewriter.Start_Rewriting (Main.Prj_Info.all, +Main.File.Full_Name);
            Add_Auto_Dump_Buffers
              (IC   => IC,
               Info => Main.Prj_Info.all,
               Main => Main.Unit,
               URH  => Libadalang.Rewriting.Handle (Rewriter.Rewritten_Unit));
            Rewriter.Apply;
         end;
      end loop;
   end Auto_Dump_Buffers_In_Ada_Mains;

   ----------------------------
   -- Remove_Old_Instr_Files --
   ----------------------------

   procedure Remove_Old_Instr_Files (IC : Inst_Context) is
      use Ada.Directories;
      use Project_Info_Maps;

   begin
      for Cur in IC.Project_Info_Map.Iterate loop
         declare
            Prj_Info   : Project_Info renames Element (Cur).all;
            Output_Dir : constant String := To_String (Prj_Info.Output_Dir);
            To_Delete  : File_Sets.Set;
            Search     : Search_Type;
            Dir_Entry  : Directory_Entry_Type;
         begin
            Start_Search
              (Search,
               Directory => Output_Dir,
               Pattern   => "",
               Filter    => (Ordinary_File => True, others => False));
            while More_Entries (Search) loop
               Get_Next_Entry (Search, Dir_Entry);
               declare
                  Name    : constant String := Simple_Name (Dir_Entry);
                  UB_Name : constant Unbounded_String :=
                     To_Unbounded_String (Name);
               begin
                  if not Prj_Info.Instr_Files.Contains (UB_Name) then
                     To_Delete.Insert (UB_Name);
                  end if;
               end;
            end loop;
            End_Search (Search);

            for Name of To_Delete loop
               Delete_File (Output_Dir / To_String (Name));
            end loop;
         end;
      end loop;
   end Remove_Old_Instr_Files;

   ----------------------------------
   -- Instrument_Units_Of_Interest --
   ----------------------------------

   procedure Instrument_Units_Of_Interest
     (ISI_Filename         : String;
      Units_Inputs         : Inputs.Inputs_Type;
      Dump_Method          : Any_Dump_Method;
      Language_Version     : Any_Language_Version;
      Ignored_Source_Files : access GNAT.Regexp.Regexp)
   is
      IC                : Inst_Context :=
         Create_Context (Dump_Method, Language_Version);
      Root_Project_Info : constant Project_Info_Access :=
         Get_Or_Create_Project_Info (IC, Project.Project.Root_Project);

      procedure Add_Instrumented_Unit
        (Project     : GNATCOLL.Projects.Project_Type;
         Source_File : GNATCOLL.Projects.File_Info);
      --  Add the given source file to the queue of units to instrument

      procedure Instrument_Unit
        (CU_Name   : Compilation_Unit_Name;
         Unit_Info : in out Instrumented_Unit_Info);
      --  Instrument a single source file of interest from the project

      ---------------------------
      -- Add_Instrumented_Unit --
      ---------------------------

      procedure Add_Instrumented_Unit
        (Project     : GNATCOLL.Projects.Project_Type;
         Source_File : GNATCOLL.Projects.File_Info)
      is
         use GNATCOLL.VFS;
      begin
         --  Skip this file if we were told to ignore it

         if Ignored_Source_Files /= null
            and then GNAT.Regexp.Match
              (+Source_File.File.Base_Name, Ignored_Source_Files.all)
         then
            return;
         end if;

         declare
            CU_Name   : constant Compilation_Unit_Name :=
              To_Compilation_Unit_Name (Source_File);
         begin
            --  If we already planned to instrument this unit, do nothing more

            if IC.Instrumented_Units.Contains (CU_Name) then
               return;
            end if;

            declare
               Unit_Info : constant Instrumented_Unit_Info_Access :=
                  new Instrumented_Unit_Info'
                    (Filename => To_Unbounded_String
                                   (+Source_File.File.Full_Name),
                     Prj_Info => Get_Or_Create_Project_Info (IC, Project),
                     Is_Main  => GNATCOLL.Projects.Is_Main_File
                                  (Project, Source_File.File.Base_Name));
            begin
               IC.Instrumented_Units.Insert (CU_Name, Unit_Info);
               IC.Instrumentation_Queue.Append (CU_Name);
            end;
         end;
      end Add_Instrumented_Unit;

      ---------------------
      -- Instrument_Unit --
      ---------------------

      procedure Instrument_Unit
        (CU_Name   : Compilation_Unit_Name;
         Unit_Info : in out Instrumented_Unit_Info)
      is
         Prj_Info : Project_Info renames Unit_Info.Prj_Info.all;
         UIC      : Unit_Inst_Context;
      begin
         --  Instrument the source file and create a unit to contain its
         --  coverage buffers.

         Instrument_Source_File
           (CU_Name   => CU_Name,
            Unit_Info => Unit_Info,
            Prj_Info  => Prj_Info,
            IC        => IC,
            UIC       => UIC);
         Emit_Buffer_Unit (Prj_Info, UIC);
         Emit_Pure_Buffer_Unit (Prj_Info, UIC);

         --  Track which CU_Id maps to which instrumented unit

         Instrumented_Unit_CUs.Insert (CU_Name, UIC.CU);
      exception
         when E : Libadalang.Common.Property_Error =>
            Report
              ("internal error while instrumenting "
               & To_String (Unit_Info.Filename) & ": "
               & Ada.Exceptions.Exception_Information (E),
               Kind => Diagnostics.Error);
      end Instrument_Unit;

   --  Start of processing for Instrument_Units_Of_Interest

   begin
      --  First get the list of all units of interest

      Project.Enumerate_Ada_Sources
        (Add_Instrumented_Unit'Access, Units_Inputs);

      --  If we need to instrument all Ada mains, also go through them now, so
      --  that we can prepare output directories for their projects later on.

      if Dump_Method /= Manual then
         for Main of Project.Enumerate_Ada_Mains loop
            Register_Main_To_Instrument (IC, Main.File, Main.Project);
         end loop;
      end if;

      --  Know that we know all the sources we need to instrument, prepare
      --  output directories.

      Prepare_Output_Dirs (IC);

      --  Instrument all units of interest

      while not IC.Instrumentation_Queue.Is_Empty loop
         declare
            use Instrumented_Unit_Maps;

            CU  : constant Compilation_Unit_Name :=
               IC.Instrumentation_Queue.First_Element;
         begin
            IC.Instrumentation_Queue.Delete_First;
            Instrument_Unit (CU, IC.Instrumented_Units.Element (CU).all);
         end;
      end loop;

      Emit_Buffers_List_Unit (IC, Root_Project_Info.all);

      --  Instrument all Ada mains that are not unit of interest to add the
      --  dump of coverage buffers: Instrument_Unit already took care of mains
      --  that are units of interest.

      Auto_Dump_Buffers_In_Ada_Mains (IC);

      --  Remove sources in IC.Output_Dir that we did not generate this time.
      --  They are probably left overs from previous instrumentations for units
      --  that are no longer of interest. It is crucial not to make them part
      --  of next builds.

      Remove_Old_Instr_Files (IC);

      --  Finally, emit an ISI file to contain mappings between bits in
      --  coverage buffers and SCOs.
      --
      --  TODO??? Remove the explicit version argument for Checkpoint_Save once
      --  the default includes support for source instrumentation.

      declare
         Context : aliased Coverage.Context := Coverage.Get_Context;
      begin
         Checkpoints.Checkpoint_Save
           (ISI_Filename,
            Context'Access,
            Purpose => Checkpoints.Instrumentation);
      end;

      if Switches.Verbose then
         SC_Obligations.Dump_All_SCOs;
      end if;
   end Instrument_Units_Of_Interest;

end Instrument;
