#!/usr/bin/env python

# ***************************************************************************
# ***                  COUVERTURE TESTSUITE MAIN DRIVER                   ***
# ***************************************************************************

"""./testsuite.py [OPTIONS] [TEST_PATH]

Run the couverture testsuite

To run tests whose relative path to test.py match a provided regexp
   ./testsuite.py I401-009
   ./testsuite.py ./tests/I4

See ./testsuite.py -h for more help
"""

# ***************************************************************************

from gnatpython.env import Env
from gnatpython.ex import Run
from gnatpython.fileutils import mkdir, rm, ln, find, which
from gnatpython.main import Main
from gnatpython.mainloop import MainLoop

from gnatpython.optfileparser import OptFileParse
from gnatpython.reports import ReportDiff

from glob import glob

import time
import logging, os, re, sys

from SUITE import cutils
from SUITE.cutils import contents_of, re_filter, clear, to_list, FatalError

from SUITE.qdata import QDregistry, QDreport, qdaf_in, QLANGUAGES, QROOTDIR

from SUITE import control
from SUITE.control import BUILDER, XCOV

DEFAULT_TIMEOUT = 600

# ==========================================
# == Qualification principles and control ==
# ==========================================

# The testsuite tree features particular subdirectories hosting TOR and
# qualification testcases. These are all hosted down a single root directory,
# and we designate the whole piece as the qualification subtree.

# These tests may be run as part of a regular testing activity or for an
# actual qualification process. The latter is indicated by passing
# --qualif-level on the command line, in which case the testsuite is said to
# run in qualification mode.

# The qualification mode aims at producing a test-results qualification report
# for the provided target level.

# The --qualif-cargs family controls the compilation options used to compile
# the the qualification tests.

# Beyond the production of a qualification report, --qualif-level has several
# effects of note:
#
#   * The set of tests exercised is restricted to the set of qualification
#     tests relevant for the target level,
#
#   * The coverage analysis tool is called with a --level corresponding to the
#     target qualification level for all the tests, whatever the criterion the
#     test was designed to assess. For example, for a target level A we will
#     invoke gnatcov --level=stmt+mcdc even for tests designed to verify
#     statement coverage only.
#
#   * For criteria with variants (e.g. unique-cause and masking mcdc),
#     exercise only the default one.

# A dictionary of information of interest for each qualification level:

class QlevelInfo:
    def __init__(self, levelid, subtrees, xcovlevel):
        self.levelid   = levelid   # string identifier

        # regexp of directory subtrees: testdirs that match this
        # hold qualification tests for this level
        self.subtrees  = subtrees

        # --level argument to pass to xcov when running such tests when in
        # qualification mode
        self.xcovlevel = xcovlevel

RE_QCOMMON="(Common|Appendix)"
RE_QLANG="(%s)" % '|'.join (QLANGUAGES)

# A regular expression that matches subdirs of qualification tests that
# should apply for coverage criteria RE_CRIT.

def RE_SUBTREE (re_crit):
    return "%(root)s/((%(common)s)|(%(lang)s/(%(crit)s)))" % {
        "root": QROOTDIR, "common": RE_QCOMMON,
        "lang": RE_QLANG, "crit": re_crit
        }

QLEVEL_INFO = {

    "doA" : QlevelInfo (
        levelid   = "doA",
        subtrees  = RE_SUBTREE (re_crit="stmt|decision|mcdc"),
        xcovlevel = "stmt+mcdc"),

    "doB" : QlevelInfo (
        levelid   = "doB",
        subtrees  = RE_SUBTREE (re_crit="stmt|decision"),
        xcovlevel = "stmt+decision"),

    "doC" : QlevelInfo (
        levelid   = "doC",
        subtrees  = RE_SUBTREE (re_crit="stmt"),
        xcovlevel = "stmt")
    }


# ===============
# == TestSuite ==
# ===============

class TestSuite:

    def __init__(self):
        """Prepare the testsuite run: parse options, compute and dump
        discriminants, compute lists of dead/non-dead tests, run gprconfig and
        build the support library for the whole series of tests to come"""

        # Parse command lines options

        # Set to True if the tests should be run under valgrind control.
        self.enable_valgrind = False

        self.options = self.__parse_options()

        # Add current directory in PYTHONPATH, allowing TestCases to find the
        # SUITE and SCOV packages
        self.env = Env()
        self.env.add_search_path('PYTHONPATH', os.getcwd())

        # Check sanity of a provided toolchain path, if any, and adjust PATH
        # accordingly
        if self.options.toolchain:
            self.setup_toolchain (self.options.toolchain)

        # Setup log directories
        self.log_dir = os.path.join (os.getcwd(), 'output')
        mkdir(self.log_dir)

        # Setup trace directories for bootstrap runs
        if self.options.bootstrap_scos != None:
            self.trace_dir = os.path.join (self.log_dir, 'traces')
            rm(self.trace_dir, recursive=True)
            mkdir(self.trace_dir)
        else:
            self.trace_dir = None

        # Generate the discs list for test.opt parsing
        discs = self.discriminants()

        # Dump the list of discriminants in a file.  We can then use that file
        # to determine which discriminants were set during a particular run.
        with open(os.path.join(self.log_dir, 'discs'), 'w') as fd:
            fd.write(" ".join(discs) + "\n")

        # Dump useful information about this run in a file.  This file can be
        # used as a testsuite report header, allowing a review to determine
        # immediately how the testsuite was run to get those results.  For
        # now, we only provide the command-line switches.

        self.comment = os.path.join(self.log_dir, 'comment')
        with open(self.comment, 'w') as fd:
            fd.write("Options: " + " ".join(_quoted_argv()) + "\n")

        # Compute the test list. Arrange to have ./ in paths to maximize
        # possible regexp matches, in particular to allow use of command-line
        # shell expansion to elaborate the expression.

        # First get a list of test.py candidates, filtered according to the
        # qualification mode and then to the user provided expression. Then
        # partition into dead/non_dead according to test.opts.

        self.non_dead_list, self.dead_list = self.partition_testcase_list(
            re_filter(
                re_filter (
                    [t for root in ["Qualif", "tests"]
                     for t in find (
                            root, pattern="test.py", follow_symlinks=True)
                     ],
                    "." if not self.options.qualif_level
                    else QLEVEL_INFO[self.options.qualif_level].subtrees),
                self.options.run_test),
            discs)

        # Report all dead tests
        with open (os.path.join(self.log_dir, 'results'), 'w') as fd:
            [fd.write('%s:DEAD:\n' % dt.filename) for dt in self.dead_list]

        # Warn about an empty non-dead list, always. This is almost
        # certainly a selection mistake in any case.

        if not self.non_dead_list:
            logging.warning (
                "List of non-dead tests to run is empty. Selection mistake ?")

        # Otherwise, advertise the number of tests to run, even in quiet mode,
        # so we have at least a minimum feedback to match what is going to run
        # against the intent.

        else:
            logging.info (
                "%d non-dead tests to run%s ..." % (
                    len(self.non_dead_list),
                    ", displaying failures only" if self.options.quiet else "")
                )

        # Compute targetprefix, prefix to designate target specific versions
        # of command line tools (a-la <prefix>-gnatmake) and expected as the
        # --target argument of other command line tools such as gprbuild or
        # gprconfig.

        targetprefix = self.env.target.triplet

        # Run the builder configuration for the testsuite as a whole. Doing
        # it here once both factorizes the work for all testcases and prevents
        # cache effects if PATH changes between testsuite runs.

        BUILDER.RUN_CONFIG_SEQUENCE (self.options)

        # Build support library as needed

        if control.need_libsupport():

            targetargs = ["TARGET=%s" % targetprefix]
            if self.options.board:
                targetargs.append ("BOARD=%s" % self.options.board)

            logfile = os.path.join (self.log_dir, 'build_support.out')

            p = Run(['make', '-C', 'support', '-f', 'Makefile.libsupport']
                    + targetargs + ["RTS=%s" % self.options.RTS],
                    output=logfile)

            if p.status != 0:
                raise FatalError (
                    ("Problem during libsupport construction. %s:\n" % logfile)
                    + contents_of (logfile))

        # Instanciate what we'll need to produce a qualfication report.
        # Do that always, even if not running for qualif. The registry will
        # just happen to be empty if we're not running for qualif.

        self.qdreg = QDregistry()

        # Initialize counter of consecutive failures, to stop the run
        # when it is visibly useless to keep going

        self.n_consecutive_failures = 0

    # -------------------------------
    # -- Discriminant computations --
    # -------------------------------

    def discriminants (self):
        """Full set of discriminants that apply to this test"""
        return (
            self.base_discriminants()
            + self.qualif_level_discriminants()
            + self.qualif_cargs_discriminants()
            + self.rts_discriminants()
            + self.toolchain_discriminants())

    def base_discriminants(self):
        return ['ALL'] + self.env.discriminants

    def qualif_cargs_discriminants(self):
        """Compute a list of discriminants (string) for each switch passed in
        all the --qualif-cargs command-line option(s).  The format of each
        discriminant QUALIF_CARGS_<X> where <X> is the switch stripped of its
        leading dashes.

        For instance, if this testsuite is called with --qualif-cargs='-O1'
        --qualif-cargs-Ada='-gnatp', then this function should return
        ['QUALIF_CARGS_gnatp', 'QUALIF_CARGS_O1'].

        Return an empty list if --qualif-cargs was not used.
        """

        allopts = ' '.join (
            [self.env.main_options.__dict__[opt] for opt in
             ("qualif_cargs" + ext
              for ext in [""] + ["_%s" % l for l in QLANGUAGES])]
            )
        return ["QUALIF_CARGS_%s" % arg.lstrip('-') for arg in allopts.split()]

    def qualif_level_discriminants(self):
        """List of single discriminant (string) denoting our current
        qualification mode, if any. This is ['QUALIF_LEVEL_XXX'] when invoked
        with --qualif-level=XXX, [] otherwise"""

        return (
            [] if not self.env.main_options.qualif_level
            else ["QUALIF_LEVEL_%s" % self.env.main_options.qualif_level]
            )

    def rts_discriminants(self):
        """Compute a list of discriminant strings that reflect the kind of
        runtime support library in use, as conveyed by the --RTS command-line
        option."""

        # --RTS=zfp is strict zfp, missing malloc, memcmp, memcpy and put

        if self.env.main_options.RTS == "zfp":
            return ["RTS_ZFP_STRICT"]

        # ex --RTS=powerpc-elf/zfp-prep

        elif re.search ("zfp", self.env.main_options.RTS):
            return ["RTS_ZFP"]

        # ex --RTS=powerpc-elf/ravenscar-sfp-prep or --RTS=ravenscar-sfp

        elif re.search ("ravenscar.*sfp", self.env.main_options.RTS):
            return ["RTS_RAVENSCAR", "RTS_RAVENSCAR_SFP"]

        # ex --RTS=powerpc-elf/ravenscar-full-prep or --RTS=ravenscar

        elif re.search ("ravenscar", self.env.main_options.RTS):
            return ["RTS_RAVENSCAR", "RTS_RAVENSCAR_FULL"]

        # ex --RTS=native or --RTS=kernel

        else:
            return ["RTS_FULL"]

        return dlist

    def toolchain_discriminants (self):
        """Compute the list of discriminants that reflect the version of the
        particular toolchain in use, if any, for example "7.0.2" for
        /path/to/gnatpro-7.0.2. The match is on the sequence of three single
        digits separated by dots."""

        m = re.search ("(\d\.[01]\.[012])", self.options.toolchain)
        return [m.group(1)] if m else []

    # -----------------------------
    # -- partition_testcase_list --
    # -----------------------------

    def partition_testcase_list(self, test_list, discs):
        """Partition TEST_LIST into a (non_dead_list, dead_list) tuple of
        sorted lists according to discriminants DISCS. Entries in both lists
        are TestCase instances.
        """

        dead_list = []
        non_dead_list = []

        for test in test_list:
            tc = TestCase(test, self.trace_dir)
            tc.parseopt(discs)
            if tc.is_dead():
                dead_list.append(tc)
            else:
                non_dead_list.append(tc)

        # Sort lists
        non_dead_list.sort()
        dead_list.sort()
        return (non_dead_list, dead_list)

    # ---------
    # -- run --
    # ---------

    def run (self):

        # Main loop : run all the tests and collect the test results, then
        # generate the human readable report. Make sure we produce a report
        # and keep going on exception as well, e.g. on stop for consecutive
        # failures threshold.

        try :
            MainLoop(self.non_dead_list,
                     self.run_testcase,
                     self.collect_result,
                     self.options.jobs)

        except Exception as e:
            logging.info("Mainloop stopped on exception occurrence")
            logging.info(e.__str__())

        ReportDiff(
            self.log_dir, self.options.old_res
            ).txt_image('rep_gnatcov')

        # Generate bootstrap results
        if self.options.bootstrap_scos != None:

            # Generate trace list file
            trace_list = glob(self.trace_dir + '/*/*.trace')
            with open(self.trace_dir + '/trace.list', 'w') as file:
                file.write("\n".join(trace_list))

            Run(['time', which(XCOV), 'coverage', '--level=stmt',
                 '--scos=@' + self.options.bootstrap_scos, '--annotate=html',
                 '@' + self.trace_dir + '/trace.list',
                 '--output-dir=' + self.trace_dir],
                output=os.path.join(self.log_dir, 'bootstrap.out'))

    # ------------------
    # -- run_testcase --
    # ------------------

    def run_testcase(self, test, _job_info):
        """MainLoop hook to run a single non-dead TEST instance. If limit is
        not set, run rlimit with DEFAULT_TIMEOUT"""

        logging.debug("Running " + test.testdir)
        timeout = test.getopt('limit')
        if timeout is None:
            timeout = DEFAULT_TIMEOUT

        # Setup test execution related files. Clear them upfront to prevent
        # accumulation across executions and bogus reuse of old contents if
        # running the test raises a premature exception, before the execution
        # script gets a chance to initialize the file itself.

        outf = test.outf()
        logf = test.logf()
        diff = test.diff()
        qdaf = test.qdaf()

        [cutils.clear (f) for f in (outf, logf, diff, qdaf)]

        testcase_cmd = [sys.executable,
                        test.filename,
                        '--report-file=' + outf,
                        '--log-file=' + logf,
                        '--target', self.env.target.platform,
                        '--timeout', str(timeout)]
        if self.enable_valgrind:
            testcase_cmd.append('--enable-valgrind')
        if self.trace_dir is not None:
            test_trace_dir = os.path.join(test.trace_dir, str(test.index))
            mkdir(test_trace_dir)
            testcase_cmd.append('--trace_dir=%s' % test_trace_dir)

        # Propagate our command line arguments as testcase options.
        #
        # Beware that we're not using 'is not None' on purpose, to prevent
        # propagating empty arguments.

        mopt = self.env.main_options

        qlevels = test.qualif_levels ()

        # In qualification mode, pass the target qualification level to
        # qualification tests and enforce the proper xcov-level

        if mopt.qualif_level and qlevels:
            testcase_cmd.append('--qualif-level=%s' % mopt.qualif_level)
            testcase_cmd.append(
                '--xcov-level=%s' % QLEVEL_INFO[mopt.qualif_level].xcovlevel)

        # Enforce cargs for tests in the qualification subtree even when not
        # in qualification mode.  We need to pass both the common cargs and
        # those specific to the test language.

        if qlevels:

            lang = test.lang()

            cargs = (
                ["qualif_cargs" + ext
                 for ext in [""] + (["_%s" % lang] if lang else [])]
                )
            cargs = ' '.join (
                [mopt.__dict__[opt] for opt in cargs if mopt.__dict__[opt]]
                )

            if cargs:
                testcase_cmd.append('--cargs=%s' % cargs)

        if mopt.board:
            testcase_cmd.append('--board=%s' % mopt.board)

        if mopt.gprmode:
            testcase_cmd.append('--gprmode')

        # If we have a kernel argument, resolve to fullpath now, providing
        # straightforward visibility to local test.py instances downtree.

        if mopt.kernel:
            testcase_cmd.append('--kernel=%s' % os.path.abspath (mopt.kernel))

        testcase_cmd.append('--RTS=%s' % mopt.RTS)

        test.start_time = time.time()

        return Run(testcase_cmd, output=diff, bg=True,
                   timeout=int(timeout) + DEFAULT_TIMEOUT)

    # --------------------
    # -- collect_result --
    # --------------------

    def collect_result(self, test, _process, _job_info):
        """MainLoop hook to collect results for a non-dead TEST instance."""

        # Several things to do once a test has run:
        # - logging (to stdout) the general test status,
        # - append a status summary to the "output/results" file,
        #   for our nightly infrastructure,
        # - see if there's a testcase object pickled around,
        #   to fetch back for the generation of a qualification
        #   test-results aggregate report.

        test.end_time = time.time()

        # Compute a few useful facts: Whether the test passed or failed,
        # if it was xfailed, with what comment, what was the error log when
        # the test failed, ...

        # Compute the actual execution status, what really happened whatever
        # what was expected;

        outf = test.outf()
        success = (
            cutils.match("==== PASSED ==================", outf)
            if os.path.exists(outf) else False)

        # If the execution failed, arrange to get a link to the err log
        # where the infrastructure expects it (typically not in the test
        # dedicated subdirectory where the original log resides)

        if not success:
            odiff = self.odiff_for(test)
            cutils.clear (odiff)
            ln(test.diff(), odiff)

        # Compute the status of this test (OK, UOK, FAILED, XFAIL) from
        # the combination of its execution success and a possible failure
        # expectation

        xfail_comment = test.getopt('xfail', None)
        xfail = xfail_comment is not None

        failed_comment = test.getopt('failed', None)

        comment = xfail_comment if xfail_comment else failed_comment

        status_dict = {
            # XFAIL?   PASSED? => status   PASSED? => status
              True:    {True:    'UOK',    False:    'OK'},
              False:   {True:    'XFAIL',  False:    'FAILED'}}

        status = status_dict[success][xfail]

        # Now log and populate "results" file

        # Avoid \ in filename for the final report
        test.filename = test.filename.replace('\\', '/')

        # File the test status + possible comment on failure

        with open(os.path.join(self.log_dir, 'results'), 'a') as result_f:
            result_f.write(''.join (
                    ["%s:%s" % (test.rname(), status),
                     ":%s" % comment.strip('"') if not success and comment
                     else ""]) + '\n')

        # Log status as needed. All tests are logged in !quiet mode.
        # Real failures are always logged.

        dsec = test.end_time - test.start_time

        if (not self.options.quiet) or (not success and not xfail):
            logging.info (
                "%-68s %s - %s %s" % (
                    test.filename,
                    "%02d m %02d s" % (dsec / 60, dsec % 60),
                    status, "(%s)" % comment if comment else "")
                )

        # Dump errlog on unexpected failure

        if self.options.diffs and not success and not xfail:
            logging.info("Error log:\n" + contents_of (test.diff()))

        # Check if we have a qualification data instance pickled around,
        # and register it for later test-results production

        self.qdreg.check_qdata (
            qdaf=test.qdaf(), status=status, comment=comment)

        # Check if we need to stop the Suite as a whole

        if status == 'FAILED':
            self.n_consecutive_failures += 1
        else:
            self.n_consecutive_failures = 0

        if self.n_consecutive_failures >= 10:
            msg = ("Stopped after %d consecutive failures"
                   % self.n_consecutive_failures)

            with open(self.comment, 'a') as fd:
                fd.write("Log: " + msg + "\n")
            raise FatalError (msg)

    def odiff_for(self, test):
        """Returns path to diff file in the suite output directory.  This file
        is used to generate report and results files."""

        filename = test.filename.replace('test.py', '')
        if filename.startswith('./'):
            filename = filename[2:]
        filename = filename.strip('/').replace('/', '-')
        return os.path.join(self.log_dir, filename + '.out')

    # -------------------
    # -- parse_options --
    # -------------------

    def __parse_options(self):
        """Parse command lines options"""

        m = Main(add_targets_options=True)
        m.add_option('--quiet', dest='quiet', action='store_true',
                     default=False, help='Quiet mode. Display test failures only')
        m.add_option('--gprmode', dest='gprmode', action='store_true',
                     default=False, help='Use -P instead of --scos')
        m.add_option('--diffs', dest='diffs', action='store_true',
                     default=False, help='show diffs on stdout')
        m.add_option('--enable-valgrind', dest='enable_valgrind',
                     action='store_true', default=False,
                     help='enable the use of valgrind when running each test')
        m.add_option('-j', '--jobs', dest='jobs', type='int',
                     metavar='N', default=1, help='Allow N jobs at once')
        m.add_option("--old-res", dest="old_res", type="string",
                        help="Old testsuite.res file")

        # qualif-cargs family: a common, language agnostic, one + one for each
        # language we support. Iterations on qualif-cargs wrt languages will
        # be performed using explicit references to the attribute dictionary
        # of m.options.

        m.add_option('--qualif-cargs', dest='qualif_cargs', metavar='ARGS',
                     help='Additional arguments to pass to the compiler '
                          'when building the test programs. Language agnostic.')

        [m.add_option(
                '--qualif-cargs-%s' % lang,
                dest='qualif_cargs_%s' % lang,
                help='qualif-cargs specific to %s tests' % lang,
                metavar="...")
         for lang in QLANGUAGES]

        m.add_option('--qualif-level', dest='qualif_level',
                     type="choice", choices=QLEVEL_INFO.keys(),
                     metavar='QUALIF_LEVEL',
                     help='State we are running in qualification mode for '
                          'a QUALIF_LEVEL target. This selects a set of '
                          'applicable tests for that level.')
        m.add_option('--bootstrap-scos', dest='bootstrap_scos',
                     metavar='BOOTSTRAP_SCOS',
                     help='scos for bootstap coverage report. '
                     'Use xcov to assess coverage of its own testsuite. '
                     'Only supported on x86-linux. '
                     'Note that it disables the use of valgrind.')
        m.add_option('--board', dest='board', metavar='BOARD',
                     help='Specific target board to exercize.')
        m.add_option('--RTS', dest='RTS', metavar='RTS',
                     help='RTS library to use, mandatory for BSP support')
        m.add_option('--kernel', dest='kernel', metavar='KERNEL',
                     help='KERNEL to pass to gnatcov run in addition to exe')
        m.add_option(
            '--toolchain', dest='toolchain', metavar='TOOLCHAIN',
            default="", help='Use toolchain in the provided path value')
        m.parse_args()

        self.enable_valgrind = (
            m.options.enable_valgrind and m.options.bootstrap_scos == None)

        if not m.options.RTS:
            m.error ("RTS argument missing, mandatory for BSP selection")

        if m.args:
            # Run only tests matching the provided regexp
            m.options.run_test = m.args[0]

            if not m.options.quiet:
                logging.info("Running tests matching '%s'" % m.options.run_test)
        else:
            m.options.run_test = ""

        # --qualif-cargs "" should be kept semantically equivalent to absence
        # of --qualif-cargs at all, and forcing a string allows simpler code
        # downstream.

        [m.options.__dict__.__setitem__ (opt, "")
         for opt in ("qualif_cargs%s" % ext
                     for ext in [""] + ["_%s" % lang for lang in QLANGUAGES])
         if m.options.__dict__[opt] == None]

        return m.options

    # ---------------------
    # -- setup_toolchain --
    # ---------------------

    def setup_toolchain (self, prefix):

        """Adjust PATH to have PREFIX/bin ahead in PATH after sanity
        checking that it contains at least a couple of programs we'll
        need (e.g. <target>-gcc and gprbuild)."""

        # Sanity check that <toolchain>/bin contains at least
        # a couple of binaries we'll need

        bindir = os.path.join (prefix, "bin")

        if (not os.path.exists (
                os.path.join (bindir, self.env.target.triplet + "-gcc"))
            or not os.path.exists (
                os.path.join (bindir, "gprbuild"))
            ):
            raise FatalError (
                'Provided toolchain dir "%s" misses essential binaries' %
                self.options.toolchain)

        # Adjust PATH to place <bindir> ahead so that the tests we
        # spawn use it.

        self.env.add_search_path(
            env_var = 'PATH', path = bindir, append = False)

# ==============
# == TestCase ==
# ==============

class TestCase(object):

    # Index to assign to the next instance of this class
    index = 0

    def __init__(self, filename, trace_dir=None):
        """Create a new TestCase for the given filename. If trace_dir
        is specified, save the bootstrap traces there."""
        self.testdir      = os.path.dirname(filename)
        self.filename     = filename
        self.expected_out = None
        self.opt          = None
        self.trace_dir    = trace_dir

        self.index        = TestCase.index
        TestCase.index += 1

    def __lt__(self, right):
        """Use filename alphabetical order"""
        return self.filename < right.filename

    # ---------------------------------
    # -- Testcase options and status --
    # ---------------------------------

    def parseopt(self, tags):
        """Parse the test.opt with the given tags"""
        test_opt = os.path.join(self.testdir, 'test.opt')
        if os.path.exists(test_opt):
            self.opt = OptFileParse(tags, test_opt)
        self.expected_out = self.getopt('out', 'test.out')

    def getopt(self, key, default=None):
        """Get the value extracted from test.opt that correspond to key

        If key is not found. Returns default.
        """
        if self.opt is None:
            return default
        else:
            return self.opt.get_value(key, default_value=default)

    def is_dead(self):
        """Returns True if the test is DEAD"""
        if self.opt is None:
            return False
        else:
            return self.opt.is_dead

    # ---------------------------
    # -- Testcase output files --
    # ---------------------------

    def outf(self):
        """Return the name of the file where outputs of the provided
        test object should go. Same location as the test source script,
        with same name + a .out extra suffix extension."""
        return os.path.join(os.getcwd(), self.filename + '.out')

    def logf(self):
        """Similar to outfile, for the file where logs of the commands
        executed by the provided test object should go."""
        return os.path.join(os.getcwd(), self.filename + '.log')

    def diff(self):
        """Similar to outf, for the file where diffs of the provided test
        object should go."""
        return os.path.join(os.getcwd(), self.filename + '.err')

    def qdaf(self):
        return qdaf_in(self.testdir)

    # -----------------------------
    # -- Testcase identification --
    # -----------------------------

    def rname(self):
        """A unique representative name for TEST"""

        filename = self.filename.replace('test.py', '')
        if filename.startswith('./'):
            filename = filename[2:]
        return filename.strip('/').replace('/', '-')

    def qualif_levels(self):
        """List of qualification levels to which SELF applies"""

        # Check which QLEVEL subtrees would match ...
        return [
            qlevel for qlevel in QLEVEL_INFO
            if re.search (QLEVEL_INFO[qlevel].subtrees, self.testdir)]

    def lang(self):
        """The language specific subtree SELF pertains to"""
        for lang in QLANGUAGES:
            if self.testdir.find ("%s/%s/" % (QROOTDIR, lang)) != -1:
                return lang
        return None

# ======================
# == Global functions ==
# ======================

def _quoted_argv():
    """Return a list of command line options used to when invoking this
    script.  The different with sys.argv is that the first entry (the
    name of this script) is stripped, and that arguments that have a space
    in them get quoted.  The goal is to be able to copy/past the quoted
    argument in a shell and obtained the desired effect."""
    quoted_args = []
    for arg in sys.argv[1:]:
        if ' ' in arg:
           eq_idx = arg.find('=')
           if eq_idx < 0:
               quoted_arg = "'" + arg + "'"
           else:
               quoted_arg = arg[:eq_idx] + "='" + arg[eq_idx + 1:] + "'"
        else:
           quoted_arg = arg
        quoted_args.append(quoted_arg)
    return quoted_args

# =================
# == script body ==
# =================

# Instanciate and run a TestSuite object ...

if __name__ == "__main__":
    suite = TestSuite()
    suite.run()

    if suite.options.qualif_level:
        QDreport(options=suite.options, qdreg=suite.qdreg)
