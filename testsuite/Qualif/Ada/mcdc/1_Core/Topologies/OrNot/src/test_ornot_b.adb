with Support, Ornot; use Support, Ornot;

procedure Test_Ornot_B is
begin
   Assert (F (False, True) = False);
   Assert (F (False, False) = True);
end;

--# ornot.adb
--  /eval(Stmt|Other)/   l! ## c!:"A"
--  /decisionTrue/  l+ ## 0
--  /decisionFalse/ l+ ## 0
--  /returnValue/   l+ ## 0
--  /decl/   l+ ## 0
