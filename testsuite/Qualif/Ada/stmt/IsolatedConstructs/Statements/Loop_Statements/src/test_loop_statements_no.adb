--  Test driver for LOOP statements. It only "with"s the functional code,
--  but does not execute anything from it, so no LOOP statement or component
--  thereof is expected to be reported as covered except loop statements from
--  the package body (they are they are fully executed as a part of package
--  elaboration, so they are expected to be reported as covered).

with LOOP_Statements;      use LOOP_Statements;
with More_LOOP_Statements; use More_LOOP_Statements;
with Support;              use Support;
procedure Test_LOOP_Statements_No is
   function My_Factorial is new Factorial (Natural);
   procedure My_Sum_First_Under_Limit is new Sum_First_Under_Limit (10);
begin
   Assert (True);
end Test_LOOP_Statements_No;

--# loop_statements.adb
-- /preLoop1/              l- s-
-- /loop1/                 l- s-
-- /inloopbeforeexit1/     l- s-
-- /inloopexit1/           l- s-
-- /inloopafterexit1/      l- s-
-- /postLoop1/             l- s-
-- /preLoop2/              l- s-
-- /loop2/                 l- s-
-- /inloopbeforeexit2/     l- s-
-- /inloopbeforeexitinif2/ l- s-
-- /inloopexit2/           l- s-
-- /preLoop3/              ~l- ~s-
-- /loop3/                 ~l- ~s-
-- /inloopexit3/           ~l- ~s-
-- /inloop3/               ~l- ~s-
-- /postLoop3/             ~l- ~s-
-- /preLoop4/              ~l- ~s-
-- /loop4/                 ~l- ~s-
-- /inloopexit4/           ~l- ~s-
-- /inloop4/               ~l- ~s-

--# more_loop_statements.adb
-- /preLoop1/    l- s-
-- /Loop1/       l- s-
-- /inLoop1/     l- s-
-- /inIfinLoop1/ l- s-
-- /postLoop1/   l- s-
-- /Loop2/       l- s-
-- /inLoop2/     l- s-
-- /inIfinLoop2/ l- s-
-- /elab/        l+ 0
