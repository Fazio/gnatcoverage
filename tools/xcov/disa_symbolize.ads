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
with Traces;

package Disa_Symbolize is
   --  Call-back used to find a relocation symbol.
   type Symbolizer is limited interface;
   procedure Symbolize (Sym : Symbolizer;
                        Pc : Traces.Pc_Type;
                        Line : in out String;
                        Line_Pos : in out Natural) is abstract;

   type Nul_Symbolizer_Type is new Symbolizer with null record;
   procedure Symbolize (Sym : Nul_Symbolizer_Type;
                        Pc : Traces.Pc_Type;
                        Line : in out String;
                        Line_Pos : in out Natural);

   Nul_Symbolizer : constant Nul_Symbolizer_Type := (others => <>);

end Disa_Symbolize;
