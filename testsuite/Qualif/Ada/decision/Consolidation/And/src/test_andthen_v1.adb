with Support, Andthen; use Support;

procedure Test_Andthen_V1 is
begin
   Assert (Andthen (True, False) = False);
end;

--# andthen.adb
--  /eval/ l! ## dT-
--  /true/  l- ## s-
--  /false/ l+ ## 0


