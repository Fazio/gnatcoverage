with Support, Notand; use Support, Notand;

procedure Test_Notand_A_SC is
begin
   Assert (F (False, True) = True);
   Assert (F (True, False) = False);
end;

--# notand.adb
--  /eval(Stmt|Other)/  l! ## c!:"B"
--  /decisionTrue/  l+ ## 0
--  /decisionFalse/ l+ ## 0
--  /returnValue/   l+ ## 0
--  /decl/   l+ ## 0
