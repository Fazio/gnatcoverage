with Support, Val_Helper; use Support, Val_Helper;

procedure Test_Val_F is
begin
   Val_Helper.Eval_F;
end;

--# val.adb
--  /eval/  l+ ## 0
--  /true/  l- ## s-
--  /false/ l+ ## 0
