with Support, Andthen; use Support, Andthen;

procedure Test_Andthen_B is
begin
   Assert (And_Then (True, True) = True);
   Assert (And_Then (True, False) = False);
end;

--# andthen.adb
--  /evaluate/  l! c!:"A"
--  /decisionTrue/  l+ 0
--  /decisionFalse/ l+ 0
--  /returnValue/   l+ 0
