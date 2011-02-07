--  Test driver for GOTO statements. It does not cause execution of the first
--  GOTO statement the functional code, but it causes execution of the second
--  GOTO statement

with GOTO_Statements;      use GOTO_Statements;
with Support;              use Support;
procedure Test_GOTO_Statements_2 is
   function My_Update is new Update_G (Integer);
begin
   Assert (My_Update (Identity (0)) = 1);
end Test_GOTO_Statements_2;

--# goto_statements.adb
-- /1if/         l+ 0
-- /1goto/       l- s-
-- /2if/         l+ 0
-- /2goto/       l+ 0
-- /after2goto/  l- s-
-- /3goto/       l- s-
-- /after3goto/  l- s-
-- /4goto/       l- s-
-- /after4goto/  l+ 0
-- /fin/         l+ 0
