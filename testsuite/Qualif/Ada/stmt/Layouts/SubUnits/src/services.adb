with Support; use Support;

package body Services is

   procedure FlipX (X : in out Integer) is separate;
   procedure FlipB (B : in out Boolean) is separate;

   procedure Dispatch (Do_Flipx, Do_Flipb : Boolean) is
      KX : constant Integer := Identity (12);
      KB : constant Boolean := Identity (True);
      B : Boolean := KB;
      X : Integer := KX;
   begin
      if Do_Flipb then
         FlipB (B);           -- # flipb
         Assert (B = not KB); -- # flipb
      end if;
      if Do_Flipx then
         FlipX (X);           -- # flipx
         Assert (X = -KX);    -- # flipx
      end if;
   end;
end;
