with Support, Orelse; use Support;

procedure Test_Orelse_V0 is
begin
   Assert (Orelse (False, False) = False);
end;

--# orelse.adb
--  /eval/ l! ## dT-
--  /true/  l- ## s-
--  /false/ l+ ## 0


