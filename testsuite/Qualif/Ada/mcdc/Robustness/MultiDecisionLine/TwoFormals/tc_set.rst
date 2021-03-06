Exercise two distinct decisions used as subprogram actuals
==========================================================

Expression variants are issued over two dimensions: "and then" vs "or else",
and operand-set-1 vs operand-set-2, with cases where

* Expressions are the same, Operand sets are the same [AndAB_AndAB],
* Expressions are the same, Operand sets are different [AndAB_AndCD],
* Expressions are different, Operand sets are the same [AndAB_OrAB],
* Expressions are different, Operand sets are different [AndAB_OrCD].

For cases operating over identical sets of two operands (A & B in the two
expressions), we first check all the possible individual vectors alone, then
all the possible combinations of 2, 3, or 4 of these without repetition.

For the other cases, we exercise combinations of situations where each
decision evaluates

* True only,
* False only,
* both True and False, demonstrating independance of one/some/all of it's
  conditions.

.. qmlink:: TCIndexImporter

   *


