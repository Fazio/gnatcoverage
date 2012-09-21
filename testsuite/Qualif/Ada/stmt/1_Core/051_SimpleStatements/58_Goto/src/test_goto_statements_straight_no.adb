--  Test driver for GOTO statements. It only "with"s the functional code,
--  but does not execute anything from it, so no GOTO statement is expected to
--  be reported as covered.

with GOTO_Statements_Straight; use GOTO_Statements_Straight;
with Support;                  use Support;
procedure Test_GOTO_Statements_Straight_No is
   function My_Update is new Update_G (Integer);
begin
   Assert (True);
end Test_GOTO_Statements_Straight_No;

--# goto_statements_straight.adb
-- /1if/         ~l- ## ~s-
-- /1goto/       ~l- ## ~s-
-- /2if/         ~l- ## ~s-
-- /2goto/       ~l- ## ~s-
-- /after2goto/  ~l- ## ~s-
-- /3goto/       ~l- ## ~s-
-- /after3goto/  ~l- ## ~s-
-- /4goto/       ~l- ## ~s-
-- /after4goto/  ~l- ## ~s-
-- /fin/         ~l- ## ~s-
