#!python

# *****************************************************************************

# This is a helper script aimed at the production and packaging of the
# GNATcoverage qualification material documents. There are three major
# documents of interest:
#
# * PLANS: the GNATcoverage "Tool Qualification Plan" document, produced
#          from
#
# * TOR  : the GNATcoverage "Tool Operational Requirements" document,
#          tree of requirements and accompanying testcase descriptions
#
# * STR  : the GNATcoverage "Software Test Results" report, summary of
#          a qualification testsuite execution for a specific configuration
#          (this target, these tool versions with such options, producing
#          such and such testsuite results)
#
# All the artifacts required to produce these documents are hosted in a GIT
# repository. This ought to be the AdaCore main "gnatcoverage" repository for
# material to be delivered.
#
# The three documents may be produced in either html or pdf format. Most of
# the time, this is achieved by using Sphinx on generated REST.
#
# Packaging essentially consists in setting up a subdir where each document
# has a dedicated place, building a toplevel index and creating a zip archive.
#
# ---
#
# An execution of this script typically proceeds with the following steps:
#
# 1) set up a git clone of the repo where the artifacts are located
#
# 2) build whatever is requested (plans, str, tor) from those artifacts,
#    producing the html or pdf document of interest + stuff we don't care
#    about (e.g. intermediate latex sources for rest->pdf),
#
# 3) move or copy the final documents in an ITEMS subdir, then maybe build
#    an index linking to the set of available items.
#
# Everything takes place in a "root" or "work" directory, specified with
# --root-dir or --work-dir.
#
# --root-dir means "use this location, making sure we're starting from
#            scratch"  where starting from scratch is enforced by checking
#            that the designated dir doesn't exist when we start.
#
# This should be used for the final production of material to be delivered,
# and the artifacts repo should be the main AdaCore repo.
#
# --work-dir means "use this location, as is". The designated dir might exist
#            already, have remnants of previous builds etc.
#
# This is useful in development mode when elaborating this or that document
# parts. Needs to be used with care and a minimum understanding of what the
# script does internally: this script is intended to be no more than a simple
# wrapper around lower level operations for each document; it is not designed
# to guarantee 100% accurate results in all situations where you restart,
# after an arbitrary number of stops at arbitrary points. Remnants of previous
# builds can cause surprising results with sphinx, for example, and restarting
# from a clean root is the simplest option at times.
#
# With --work-dir, the target dir might already have a clone setup. By
# default, a selected git source is re-cloned there. --git-reuse and
# --git-pull provide alternate options.
#
# When cloning in a work dir that doesn't have a clone already, or when
# re-cloning when neither --git-reuse not --git-pull is requested,
# --git-source lets you state which repo is to be cloned. In absence of an
# explicit source, the main AdaCore git repo for GNATcoverage is selected.

# *****************************************************************************

from gnatpython.ex import Run
from gnatpython.fileutils import cp, mv, rm, mkdir

from datetime import date

import optparse, sys, os.path, shutil

# =======================================================================
# ==                         MISC UTILITY FUNCTIONS                    ==
# =======================================================================

class Error (Exception):
    def __init__(self):
        pass

def fail_if (p, msg):
    if p:
        print msg
        raise Error

def exit_if (p, msg):
    if p:
        print msg
        sys.exit(1)

def contents_of(filename):
    with open(filename) as fd:
        return fd.read()

def run_list (cmd, out=None, env=None):
    print "from : %s" % os.getcwd()
    print "run  : %s" % ' '.join(cmd)

    if out == None:
        out = cmd[0]+".log"

    p = Run (cmd, output=out, env=env)

    fail_if (
        p.status != 0, "execution failed\n"
        + "log was:\n" + contents_of(out))

def run (s, out=None, env=None):
    run_list (s.split())

def announce (s):
    print "=========== " + s

def remove (path):
    """Delete the file or directory subtree designated by PATH"""

    # To prevent big damage if the input PATH argument happens to have been
    # miscomputed, we first attempt to move it locally, then remove the local
    # instance. The absence of computation on this local name makes it a tad
    # safer to manipulate and the attempt to move locally would fail for
    # obviously bogus arguments such as anything leading to a parent of the
    # current dir (e.g. "/", or ...).

    local_name = "./old_stuff_to_be_removed"

    # Note that what we have to remove maybe be a regular filee or an entire
    # directory subtree and that rm("recursive=True") is not guaranteed to
    # work for regular files.

    # Start by removing the current local instance, in case the previous
    # removal failed or was interrupted somehow.

    if os.path.exists (local_name):
        rm (local_name, recursive=os.path.isdir(local_name))

    if os.path.exists (path):
        mv (path, local_name)
        rm (local_name, recursive=os.path.isdir(local_name))

# =======================================================================
# ==              QUALIF MATERIAL GENERATION HELPER CLASS              ==
# =======================================================================

sphinx_target_for = {
    "html": "html",
    "pdf" : "latexpdf"
    }

# The master GIT repo where our source artifacts reside
GIT_MASTER = "ssh://git.eu.adacore.com/scmrepos/git/gnatcoverage"

# The subdir name for this clone, relative to --root
GIT_CLONE_SUBDIR = "gnatcoverage-git-clone"

class QMAT:

    def __init__(self, options):

        self.o = options

        self.rootdir =  os.path.abspath (
            options.rootdir if options.rootdir else options.workdir)
        self.itemsdir = os.path.join (self.rootdir, "ITEMS")

        self.repodir = os.path.join (self.rootdir, GIT_CLONE_SUBDIR)

    # --------------------
    # -- setup_basedirs --
    # --------------------

    def setup_basedirs (self):

        announce ("setting up working dirs from %s" % self.rootdir)

        mkdir (self.rootdir)
        mkdir (self.itemsdir)


    # ----------------
    # -- git_update --
    # ----------------

    def git_update (self):

        # If we're requested to pull/update only, do so

        if self.o.gitpull:
            announce ("updating git clone from origin")

            os.chdir(self.repodir)
            run ("git pull --rebase origin")
            return

        # If we're requested to reuse an existing clone, do so

        if self.o.gitreuse:
            announce ("reusing existing git clone")
            return

        # Otherwise, get a fresh clone.

        os.chdir(self.rootdir)

        gitref = (
            self.o.gitsource if self.o.gitsource
            else GIT_MASTER
            )

        announce ("cloning git repository from %s" % gitref)

        remove (GIT_CLONE_SUBDIR)
        run ("git clone %s %s" % (gitref, GIT_CLONE_SUBDIR))

    # ----------------------
    # -- switch_to_branch --
    # ----------------------

    def switch_to_branch (self):
        announce ("switching to branch '%s'" % self.o.branchname)

        os.chdir(self.repodir)
        run ("git checkout %s" % self.o.branchname)

    # ----------------
    # -- latch_into --
    # ----------------

    # Helper for the various build_ methods below.

    # html builds are voluminous and tree-ish. Other builds might produce
    # secondary pieces we don't need (e.g. latex sources & stuff) and we
    # only care about the final file at the end.

    # For tree builds, we just rename the whole sphinx build tree as our
    # result. For other builds, we use a wildcard copy so the actual file
    # name doesn't matter:

    def __latch_into (self, dir, partname, toplevel):

        this_target_is_tree = (self.o.docformat == 'html')

        this_target_suffix = (
            '' if this_target_is_tree else '.%s' % self.o.docformat)

        this_target = (
            dir if toplevel and this_target_is_tree
            else os.path.join (
                dir, "%(part)s%(suffix)s" % {
                    "part": partname,
                    "suffix": this_target_suffix }
                )
            )

        this_build_subdir = os.path.join (
            "build", sphinx_target_for[self.o.docformat])

        # Delete an old version of latched results that might
        # already be there if we're running with --work-dir.
        remove (this_target)

        if this_target_is_tree:
            mv (this_build_subdir,
                this_target)
        else:
            cp (this_build_subdir + "/*.%s" % self.o.docformat,
                this_target)

        print "%s %s available in %s %s" % (
            self.o.docformat, partname,
            this_target, "(toplevel)" if toplevel else ""
            )

    # ---------------
    # -- build_tor --
    # ---------------

    def build_tor (self):
        announce ("building TOR")

        # Building the TOR documents involves generating REST
        # from the artifacts in the testsuite/Qualif tree, then
        # invoking sphinx to produce the document. This is all
        # driven by a Makefile:

        os.chdir (
            os.path.join (
                self.repodir, "qualification", "tor", "scripts")
            )

        run ("make clean")
        
        run_list (
            ['python', 'genrest.py', '--dolevel=%s' % self.o.dolevel])

        run ("make %(fmt)s " % {
                "fmt" : sphinx_target_for[self.o.docformat]}
             )

        self.__latch_into (
            dir=self.itemsdir, partname="TOR", toplevel=False)

    # ---------------
    # -- run_tests --
    # ---------------

    def run_tests (self):
        announce ("    running tests")

        # This function runs the test cases, as part of the build_str
        # functionality.

        # Running the testsuite in qualif mode (--qualif-level),
        # producing REST from results dropped by each testcase execution:

        os.chdir (os.path.join (self.repodir, "testsuite"))

        if not os.path.exists ("support"):
            orisupport = os.path.join (
                "..", "tools", "gnatcov", "examples", "support")
            if os.path.exists (orisupport):
                shutil.move (orisupport, "support")

        base_cmd = (
            "python testsuite.py "
            "--target=ppc-elf --RTS=powerpc-elf/zfp-prep "
            "--qualif-level=%s -j4" % self.o.dolevel
            )

        all_cargs = []
        if self.o.cargs:
            all_cargs.append ('--cargs=%s' % self.o.cargs)
        if self.o.cargs_ada:
            all_cargs.append ('--cargs:Ada="%s"' % self.o.cargs_ada)

        re_tests_args = (
            [] if self.o.re_tests is None else [self.o.re_tests])

        run_list (
            base_cmd.split() + all_cargs + re_tests_args
            )

    # ---------------
    # -- build_str --
    # ---------------

    def build_str (self):
        announce ("building STR")

        # Building the STR document first involves running the testsuite
        # (unless the --results-dir option was specified, indicating that
        # the test execution already occurred), and then uses to sphinx
        # to produce the document from REST.

        if self.o.resultsdir is None:
            self.run_tests ()

        # Then resort to sphinx to produce the document from REST, in the
        # requested output format:

        os.chdir (os.path.join (self.repodir, "testsuite", "qreport"))

        # If --results-dir was specified, then pass the directory containing
        # the test results to the makefile.
        if self.o.resultsdir is not None:
            run ("make %s SRCDIR=%s" % (sphinx_target_for[self.o.docformat], 
              self.o.resultsdir
            ))
        else:
            run ("make %s" % sphinx_target_for[self.o.docformat]) 

        self.__latch_into (
            dir=self.itemsdir, partname="STR", toplevel=False)

    # -----------------
    # -- build_plans --
    # -----------------

    def build_plans (self):
        announce ("building PLANS")

        # The plans are managed as QM data

        os.chdir (
            os.path.join (self.repodir, "qualification", "qm")
            )
        run ("qmachine model.xml -l scripts/generate_plans_%s.py" \
                 % self.o.docformat)

        self.__latch_into (
            dir=self.itemsdir, partname="PLANS", toplevel=False)

    # ----------------
    # -- build_pack --
    # ----------------

    def build_pack (self):
        announce ("building INDEX")

        os.chdir (os.path.join (self.repodir, "qualification", "index"))

        # We have distinct index sources for each docformat, that designate
        # each part with the appropriate location and extension (links pointing
        # to ITEMS/<part>/index.html or to ITEMS/<part>.pdf for example)

        # Rename the one we need and generate our index from there. This will
        # be doing cross document referencing.

        sphinx_target = sphinx_target_for[self.o.docformat]

        cp ("source/index_%s_rst" % self.o.docformat, "source/index.rst")
        run ("make %s" % sphinx_target)

        packroot = os.path.join (self.rootdir, self.o.pname)
        remove (packroot)
        mkdir (packroot)

        self.__latch_into (
            dir=packroot, partname=self.o.pname, toplevel=True)
        shutil.move (self.itemsdir, packroot)

        os.chdir (self.rootdir)

        run ("zip -q -r %(packname)s.zip %(packname)s" % {
                "packname": self.o.pname})

# =======================================================================
# ==                          MAIN SCRIPT BODY                         ==
# =======================================================================

valid_docformats = ('html', 'pdf')
valid_parts      = ('tor', 'str', 'plans')
valid_dolevels   = ('doA', 'doB', 'doC')

if __name__ == "__main__":

    op = optparse.OptionParser(usage="%prog <options>")

    op.add_option (
        "--root-dir", dest="rootdir",
        help=(
            "Name of a directory where a from-scratch kit construction "
            "will take place. Must not exist already.")
        )
    op.add_option (
        "--work-dir", dest="workdir",
        help=(
            "Name of a directory from where a previous kit construction "
            "will resume. Must exist already.")
        )

    op.add_option (
        "--git-source", dest="gitsource", default=None,
        help=(
            "Git repo we should be cloning to get our source artifacts. "
            "!! This overrides whatever is in a --work-dir already !!"
            )
        )
    op.add_option (
        "--git-pull", dest="gitpull", action="store_true", default=False,
        help=(
            "Pull commits from current origin in the git clone setup "
            "in work-dir."
            )
        )
    op.add_option (
        "--git-reuse", dest="gitreuse", action="store_true", default=False,
        help=(
            "Reuse current git clone setup in work-dir, as-is. "
            )
        )

    op.add_option (
        "--package-name", dest="pname",
        help=(
            "Base name of the .zip archive that will contain the full set of "
            "items bundled together. Ignored if the set of constructed items "
            "is specified explicitly.")
        )
    op.add_option ("-t", "--re_tests", dest="re_tests")
    op.add_option ("-c", "--re_chapters", dest="re_chapters")

    op.add_option (
        "--docformat", dest="docformat", default="html",
        type='choice', choices=valid_docformats,
        help = (
            "The format we need to produce for each document %s."
            "One of %s." % (valid_parts.__str__(), valid_docformats.__str__()))
        )
    op.add_option (
        "--parts", dest="parts", default=None,
        help = (
            "A comma separated list of the parts of the qualkit that "
            "are to be generated, subset of %s." % valid_parts.__str__())
        )
    op.add_option (
        "--branch", dest="branchname", default="opendo",
        help = (
            "The git branch we shall produce the material from.")
        )
    op.add_option (
        "--dolevel", dest="dolevel", default=None,
        type='choice', choices=valid_dolevels,
        help = (
            "Target DO178 qualification level. One of %s." \
                % valid_dolevels.__str__())
        )
    op.add_option (
        "--cargs", dest="cargs",
        help = (
            "Language agnostic compilation flags (-O0, -O1, ...)")
        )
    op.add_option (
        "--cargs:Ada", dest="cargs_ada",
        help = (
            "Ada specific compilation flags (-gnatp, -gnatn, ...)")
        )
    op.add_option (
        "--results-dir", dest="resultsdir", default=None,
        help = (
            "Name of a directory containing results (in .rst form) from"
            "a previous test execution run.")
        )

    (options, args) = op.parse_args()

    # work dir vs root dir.

    exit_if (
        not options.workdir and not options.rootdir,
        "A root work dir must be specified (--root-dir or --work-dir)"
        )

    exit_if (
        options.workdir and options.rootdir,
        "--root-dir and --work-dir may not be combined together."
        )

    exit_if (
        options.rootdir and os.path.exists (options.rootdir),
        "The --root-dir location (%s) must not exist already" \
            % options.rootdir
        )

    exit_if (
        options.pname and options.parts,
        ("No archive (--pname) may be generated with "
         "only parts of the kit (--parts).")
        )

    # If we are generating a full kit, we need to produce an archive.
    # Pick a default name if none was specified:

    if not options.parts and not options.pname:
        today = date.today()
        options.pname = "GNATCOV-QMAT-%s-%4d-%02d-%02d" % (
            options.docformat.upper(), today.year, today.month, today.day)

    # Settle on the set of documents we are to produce:

    options.parts = (
        valid_parts if not options.parts
        else options.parts.split(',')
        )

    [exit_if (
            part not in valid_parts,
            "Requested part '%s' is invalid, none of %s" \
                % (part, valid_parts.__str__())
            )
     for part in options.parts]

    exit_if (
        'str' in options.parts and not options.dolevel,
        ("Producing STR requires an explicit dolevel (--dolevel).")
        )

    exit_if (
        'tor' in options.parts and not options.dolevel,
        ("Producing TOR requires an explicit dolevel (--dolevel).")
        )

    # Instanciate our helper and proceed with the base
    # directory setup:

    qmat = QMAT (options=options)

    qmat.setup_basedirs()

    exit_if (
        options.gitpull and options.gitsource,
        "Specifying git source is incompatible with request to pull from current origin"
        )
    qmat.git_update()

    qmat.switch_to_branch()

    # Produce each part we are requested to produce:

    if 'tor' in options.parts:
        qmat.build_tor()

    if 'str' in options.parts:
        qmat.build_str()

    if 'plans' in options.parts:
        qmat.build_plans()

    # If we have a package to produce, do so:

    if options.pname:
        qmat.build_pack()
