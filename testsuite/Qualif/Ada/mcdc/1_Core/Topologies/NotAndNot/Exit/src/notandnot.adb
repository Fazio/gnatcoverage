package body Notandnot is

   function F (A, B : Boolean) return Boolean is
   begin
      loop
         exit when (not A) and then (not B);  -- # evalStmt :o/d:
         return False;            -- # decisionFalse
      end loop;
      return True;                -- # decisionTrue
   end;
end;
