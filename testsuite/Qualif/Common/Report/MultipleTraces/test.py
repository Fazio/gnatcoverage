from SCOV.tc import *
from SCOV.report import ReportChecker

category="stmt"
TestCase(category=category).run()
ReportChecker("cons_sort_gtin", ntraces=2, category=category).run()
thistest.result()
