with Support, Andidor; use Support, Andidor;

procedure Test_Andidor_T_F is
begin
   Assert (F (True, False, False) = False);
end;

--# andidor.adb
-- /evaluate/      l! dT-:"A",dT-:"B"
-- /decisionTrue/  l- s-
-- /decisionFalse/ l+ 0
-- /returnValue/   l+ 0
