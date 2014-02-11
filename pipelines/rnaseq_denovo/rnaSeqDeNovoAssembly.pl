#!/usr/bin/perl

=head1 NAME

I<rnaSeqDeNovoAssembly>

=head1 SYNOPSIS

perl rnaSeqDeNovoAssembly.pl -c rnaSeqDeNovo.abacus.ini -n project.nanuq.csv -d design.csv -w  currentDirectory -s 1 -e 11 > toRun.sh

Options:

  -c (rnaSeqDeNovo.abacus.ini) the standard configuration file for the pipeline.
  -s The start step
  -e The end step
  -n (project.nanuq.csv) the NANUQ Project sample file
  -d (design.csv) the design file. A tab separated value file that specifies the experimental design information of the project.
  -w The project's working directory. All job outputs will be sent to this directory.

=head1 DESCRIPTION

B<rnaSeqDeNovoAssembly.pl> is the main RNA-Seq De Novo assembly pipeline.

=head1 AUTHORS

B<David Morais> - I<dmorais@cs.bris.ac.uk>

B<Mathieu Bourgey> - I<mbourgey@genomequebec.com>

B<Joel Fillon> - I<joel.fillon@mcgill.ca>

=head1 DEPENDENCY

B<Pod::Usage> Usage and help output.

B<Cwd> Path parsing

B<Getopt::Std>  Options parsing

B<GqSeqUtils>  Deliverable and final report generation

B<LoadConfig> Configuration file parsing

B<Metrics>   Multiple metrics functions (trim/align/annotation)

B<SampleSheet> Sample sheet file parsing

B<SubmitToCluster> Cluster job options submission to the bash command, jobs resuming control

B<Trimmomatic>  Trimmomatic trimming / clipping functions

B<Trinity>  Trinity RNA-Seq De Novo assembly functions

=cut

# Strict Pragmas
#---------------
use strict qw(vars subs);
use warnings;
#---------------------

# Add the mugqic_pipeline/lib/ path relative to this Perl script to @INC library search variable
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Dependency modules
#-------------------
use Cwd 'abs_path';
use Getopt::Std;
use GqSeqUtils;
use LoadConfig;
use Metrics;
use SampleSheet;
use SubmitToCluster;
use Trimmomatic;
use Trinity;

# Steps array: each step is run globally or per sample and has a list of parent steps defining step job dependencies
#-------------
my @A_steps = (
  {
    'name'   => 'trim',
    'loop'   => 'sample',
    'parent' => []
  },
  {
    'name'   => 'normalization',
    'loop'   => 'global',
    'parent' => ['trim']
  },
  {
    'name'   => 'trinity',
    'loop'   => 'global',
    'parent' => ['normalization']
  },
  {
    'name'   => 'blastSplitQuery',
    'loop'   => 'global',
    'parent' => ['trinity']
  },
  {
    'name'   => 'blast',
    'loop'   => 'global',
    'parent' => ['blastSplitQuery']
  },
  {
    'name'   => 'blastMergeResults',
    'loop'   => 'global',
    'parent' => ['blast']
  },
  {
    'name'   => 'rsemPrepareReference',
    'loop'   => 'global',
    'parent' => ['trinity']
  },
  {
    'name'   => 'rsem',
    'loop'   => 'sample',
    'parent' => ['rsemPrepareReference']
  },
  {
    'name'   => 'differentialGeneExpression',
    'loop'   => 'global',
    'parent' => ['rsem', 'blastMergeResults']
  },
  {
    'name'   => 'metrics',
    'loop'   => 'global',
    'parent' => ['normalization']
  },
  {
    'name'   => 'deliverable',
    'loop'   => 'global',
    'parent' => ['metrics', 'differentialGeneExpression']
  }
);

# Create step hash indexed by step name for easy retrieval
my %H_steps =  map {$_->{'name'} => $_} @A_steps;

# Global variables passed as script options
my $configFile;
my $nanuqSampleSheet;
my $workDirectory;
my $designFile;

# Main call
main();

# General pipeline functions
#---------------------------
sub getUsage {
  my $usage = <<END;
Usage: perl $0 -h | -c CONFIG_FILE -s start_step_num -e end_step_num [-n SAMPLE_SHEET] [-d DESIGN_FILE] [-w WORK_DIR]
  -h  help and usage
  -c  .ini config file
  -s  start step, inclusive
  -e  end step, inclusive
  -n  nanuq sample sheet
  -d  design file
  -w  work directory (default current)

Steps:
END

  # List and number step names
  for (my $i = 1; $i <= @A_steps; $i++) {
    $usage .= $i . "- " . $A_steps[$i - 1]->{'name'} . "\n";
  }

  return $usage;
}

sub main {
  # Check options
  my %opts;
  getopts('hc:s:e:n:d:w:', \%opts);

  if (defined($opts{'h'}) ||
     !defined($opts{'c'}) ||
     !defined($opts{'s'}) ||
     !defined($opts{'e'})) {
    die (getUsage());
  }

  # Assign options
  my $startStep = $opts{'s'};
  my $endStep = $opts{'e'};
  $configFile = $opts{'c'};
  $nanuqSampleSheet = $opts{'n'};
  $designFile = $opts{'d'};
  $workDirectory = $opts{'w'};

  # Get config values
  unless (defined $configFile) {die "Error: configuration file is not defined! (use -c option)\n" . getUsage()};
  unless (-f $configFile) {die "Error: configuration file $configFile does not exist!\n" . getUsage()};
  my %cfg = LoadConfig->readConfigFile($configFile);

  SubmitToCluster::initPipeline($workDirectory);

  # Go through steps and create global or sample jobs accordingly
  for (my $i = $startStep; $i <= $endStep; $i++) {
    my $step = $A_steps[$i - 1];
    my $stepName = $step->{'name'};
    $step->{'jobIds'} = ();

    # Sample step creates 1 job per sample
    if ($step->{'loop'} eq 'sample') {
      # Nanuq sample sheet is only necessary for sample steps
      unless (defined $nanuqSampleSheet) {die "Error: nanuq sample sheet is not defined! (use -n option)\n" . getUsage()};
      unless (-f $nanuqSampleSheet) {die "Error: nanuq sample sheet $nanuqSampleSheet does not exist!\n" . getUsage()};

      my $rHoAoH_sampleInfo = SampleSheet::parseSampleSheetAsHash($nanuqSampleSheet);
      foreach my $sample (keys %$rHoAoH_sampleInfo) {
        my $rAoH_sampleLanes = $rHoAoH_sampleInfo->{$sample};
        # Sample step functions need sample and lanes parameters
        &$stepName(\%cfg, $step, $workDirectory, $sample, $rAoH_sampleLanes);
      }
    # Global step creates 1 job only
    } else {
      &$stepName(\%cfg, $step, $workDirectory);
    }
  }
}

# Generic job submission function; sample parameter is undefined for global steps
sub submitJob {
  my $rH_cfg = shift;
  my $step = shift;
  my $sample = shift;
  my $rO_job = shift;

  # Set job name after uppercased step name and, if sample step, sample name
  my $stepName = $step->{'name'};
  my $jobIdPrefix = uc($stepName);
  my $jobIds = $jobIdPrefix . "_JOB_IDS";
  if (defined $sample) {
    $jobIdPrefix .= "_" . $sample;
  }

  # Set job dependencies
  my $dependencies = "";

  # Retrieve the list of step parents
  my @A_stepParents = map {$H_steps{$_}} @{$step->{'parent'}};

  # Retrieve the list of lists of step parent job IDs if any
  my @AoA_stepParentJobIds = map {defined $_->{'jobIds'} ? $_->{'jobIds'} : []} @A_stepParents;

  # Flatten this list
  my @A_stepParentJobIds = map {@$_} @AoA_stepParentJobIds;

  # Concatenate all job IDs with cluster dependency separator
  $dependencies = join (getParam($rH_cfg, 'default', 'clusterDependencySep'), map {"\$" . $_} @A_stepParentJobIds);

  # Write out the job submission
  my $jobId = SubmitToCluster::printSubmitCmd($rH_cfg, $stepName, undef, $jobIdPrefix, $dependencies, $sample, $rO_job);

  # Store step job ID for future dependencies retrieval
  push (@{$step->{'jobIds'}}, $jobId);
}

# Return parameter value from configuration file or die if this parameter is not defined
sub getParam {
  my $rH_cfg = shift;
  my $section = shift;
  my $paramName = shift;

  my $paramValue = LoadConfig::getParam($rH_cfg, $section, $paramName);

  if ($paramValue) {
    return $paramValue;
  } else {
    die "Error: parameter \"[" . $section . "] " . $paramName . "\" is not defined in $configFile";
  }
}

# Return "module load ..." command string from the given list of modules as [[section, moduleVersion], ...]
sub moduleLoad {
  my $rH_cfg = shift;
  my $rA_modules = shift;

  # Retrieve module values from the configuration file
  my @moduleValues = map {getParam($rH_cfg, $_->[0], $_->[1])} @$rA_modules;

  # Check by a system call if module is available
  for my $moduleValue (@moduleValues) {
    my $moduleShowOutput = `source /etc/profile.d/modules.sh; module show $moduleValue 2>&1`;
    $moduleShowOutput !~ /Error/i or die "Error in $configFile:\n$moduleShowOutput";
  }

  return "module load " . join(" ", @moduleValues) . "\n";
}


# Step functions
#---------------

sub trim {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;
  my $sample = shift;
  my $rAoH_sampleLanes = shift;

  # Check raw read directory
  my $rawReadDirectory = getParam($rH_cfg, 'default', 'rawReadDir');
  unless (-d $rawReadDirectory) {die "Error in $configFile: raw read directory $rawReadDirectory does not exist or is not a directory!\n"};

  # Create trim job per sample per lane
  for my $rH_laneInfo (@$rAoH_sampleLanes) {

    my $trimDirectory = "\$WORK_DIR/reads/$sample/run" . $rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'};
    print "mkdir -p $trimDirectory\n";
    my $rO_job = Trimmomatic::trim($rH_cfg, $sample, $rH_laneInfo, $trimDirectory);

    submitJob($rH_cfg, $step, $sample, $rO_job);
  }
}

sub normalization {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $rO_job = Trinity::normalize_by_kmer_coverage($rH_cfg, $workDirectory);
  submitJob($rH_cfg, $step, undef, $rO_job);
}

sub trinity {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $rO_job = Trinity::trinity($rH_cfg, $workDirectory);
  submitJob($rH_cfg, $step, undef, $rO_job);
}

sub blastSplitQuery {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $rO_job = new Job();
  if (!$rO_job->isUp2Date()) {
    my $command = "\n";

    $command .= moduleLoad($rH_cfg, [
      ['blast', 'moduleVersion.exonerate']
    ]);

    my $trinityFastaFile = "\$WORK_DIR/trinity_out_dir/Trinity.fasta";
    my $trinityIndexFile = "\$WORK_DIR/trinity_out_dir/Trinity.idx";
    my $reducedTrinityFastaFile = "\$WORK_DIR/trinity_out_dir/Trinity.longest_transcript.fasta";

    # Remove previous Trinity assembly FASTA index if present
    $command .= "rm -f $trinityIndexFile\n";
    # Create Trinity assembly FASTA index
    $command .= "fastaindex $trinityFastaFile $trinityIndexFile\n";
    # Create Trinity assembly FASTA subset with longest transcript per component only
    $command .= "fastalength $trinityFastaFile | perl -pe 's/ ((\\S+)_seq\\S+)/\\t\\1\\t\\2/' | sort -k3,3 -k1,1gr | uniq -f2 | cut -f2 | fastafetch $trinityFastaFile -i $trinityIndexFile -q stdin > $reducedTrinityFastaFile\n";

    # Split Trinity assembly FASTA into chunks for BLAST parallelization
    my $chunkDir = "\$WORK_DIR/blast/chunks";
    $command .= "mkdir -p $chunkDir\n";
    $command .= "fastasplit -f $reducedTrinityFastaFile -o $chunkDir -c " . getParam($rH_cfg, 'blast', 'blastJobs') . " \\\n";

    $rO_job->addCommand($command);
  }
  submitJob($rH_cfg, $step, undef, $rO_job);
}

sub blast {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $numJobs = getParam($rH_cfg, 'blast', 'blastJobs');

  for (my $jobIndex = 0; $jobIndex < $numJobs; $jobIndex++) {
    # fastasplit creates FASTA chunk files numbered with 7 digits and padded with leading 0s
    my $chunkIndex = sprintf("%07d", $jobIndex);

    my $rO_job = new Job();
    if (!$rO_job->isUp2Date()) {
      my $command = "\n";

      $command .= moduleLoad($rH_cfg, [
        ['blast', 'moduleVersion.tools'],
        ['blast', 'moduleVersion.exonerate'],
        ['blast', 'moduleVersion.blast']
      ]);

      my $cores = getParam($rH_cfg, 'blast', 'blastCPUperJob');
      my $program = getParam($rH_cfg, 'blast', 'blastProgram');
      my $db = getParam($rH_cfg, 'blast', 'blastDb');
      my $options = getParam($rH_cfg, 'blast', 'blastOptions');
      my $chunkDir = "\$WORK_DIR/blast/chunks";
      my $chunkQuery = "$chunkDir/Trinity.longest_transcript.fasta_chunk_$chunkIndex";
      my $chunkResult = "$chunkDir/$program" . "_Trinity.longest_transcript_$db" . "_chunk_$chunkIndex.tsv";

      # Each FASTA chunk is further divided in subchunk per CPU per job as a second level of BLAST parallelization
      # The user must adjust BLAST configuration to optimize num. jobs vs num. CPUs per job, depending on the cluster
      $command .= "parallelBlast.pl -file $chunkQuery --OUT $chunkResult -n $cores --BLAST \\\"$program -db $db $options\\\"";

      $rO_job->addCommand($command);
    }
    submitJob($rH_cfg, $step, "blast_chunk_$jobIndex", $rO_job);
  }
}

sub blastMergeResults {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $rO_job = new Job();
  if (!$rO_job->isUp2Date()) {
    my $command = "\n";

    my $program = getParam($rH_cfg, 'blast', 'blastProgram');
    my $db = getParam($rH_cfg, 'blast', 'blastDb');
    my $blastDir = "\$WORK_DIR/blast";
    my $chunkResults = "$blastDir/chunks/$program" . "_Trinity.longest_transcript_$db" . "_chunk_*.tsv";
    my $result = "$blastDir/$program" . "_Trinity.longest_transcript_$db.tsv";

    # All BLAST chunks are merged into one file named after BLAST program and reference database
    $command .= "cat $chunkResults > $result.tmp\n";
    # Remove all comment lines except "Fields" one which is placed as first line
    $command .= "cat <(grep -m1 '^# Fields' $result.tmp) <(grep -v '^#' $result.tmp) > $result\n";
    $command .= "rm $result.tmp\n";

    # Create a BLAST results ZIP file for future deliverables
    $command .= "gzip -c $result > $result.gz";

    $rO_job->addCommand($command);
  }
  submitJob($rH_cfg, $step, undef, $rO_job);
}

# The RSEM reference assembly is created once only, and then used by all RSEM sample jobs in parallel
sub rsemPrepareReference {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $rO_job = Trinity::rsemPrepareReference($rH_cfg, $workDirectory);
  submitJob($rH_cfg, $step, undef, $rO_job);
}

# RSEM abundance estimation is performed by sample
sub rsem {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;
  my $sample = shift;

  my $rO_job = Trinity::rsem($rH_cfg, $workDirectory, $sample);
  submitJob($rH_cfg, $step, $sample, $rO_job);
}

sub differentialGeneExpression {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $rO_job = new Job();
  if (!$rO_job->isUp2Date()) {

    # Check design file
    unless (defined $designFile) {die "Error: design file is not defined! (use -d option)\n" . getUsage()};
    unless (-f $designFile) {die "Error: design file $designFile does not exist!\n" . getUsage()};
    $designFile = abs_path($designFile);

    my $command = "\n";

    # Retrieve BLAST result file
    my $program = getParam($rH_cfg, 'blast', 'blastProgram');
    my $db = getParam($rH_cfg, 'blast', 'blastDb');
    my $blastDir = "\$WORK_DIR/blast";
    my $blastResult = "$blastDir/$program" . "_Trinity_$db.tsv";

    my $dgeDir = "\$WORK_DIR/DGE";
    my $isoformsMatrix = "$dgeDir/isoforms.counts.matrix";
    my $isoformsAnnotatedMatrix = "$dgeDir/isoforms.annotated.counts.matrix";
    my $genesMatrix = "$dgeDir/genes.counts.matrix";
    my $genesAnnotatedMatrix = "$dgeDir/genes.annotated.counts.matrix";

    $command .= moduleLoad($rH_cfg, [
      ['differentialGeneExpression', 'moduleVersion.trinity'],
      ['differentialGeneExpression', 'moduleVersion.cranR'],
      ['differentialGeneExpression', 'moduleVersion.tools']
    ]);

    $command .= "mkdir -p $dgeDir\n";

    # Create isoforms and genes matrices with counts of RNA-seq fragments per feature using Trinity RSEM utility
    $command .= "merge_RSEM_frag_counts_single_table.pl \$WORK_DIR/rsem/*/*.isoforms.results > $isoformsMatrix\n";
    $command .= "merge_RSEM_frag_counts_single_table.pl \$WORK_DIR/rsem/*/*.genes.results > $genesMatrix\n";

    # Extract isoforms and genes length values
    $command .= "find \$WORK_DIR/rsem/ -name *.isoforms.results -exec cut -f 1,3,4 {} \\; -quit > \$WORK_DIR/rsem/isoforms.lengths.tsv \n";
    $command .= "find \$WORK_DIR/rsem/ -name *.genes.results -exec cut -f 1,3,4 {} \\; -quit > \$WORK_DIR/rsem/genes.lengths.tsv \n";

    # Merge isoforms and genes matrices with BLAST annotations if any:
    # edger.R requires a matrix with gene/isoform annotation as second column 
    # Keep BLAST best hit only
    # Remove from column headers ".(genes|isoforms).results" created by RSEM
    $command .= "grep -v '^#' $blastResult | awk '!x[\\\$1]++' | awk -F\\\"\\t\\\" 'FNR==NR {a[\\\$1]=\\\$2; next}{OFS=\\\"\\t\\\"; if (a[\\\$1]) {print \\\$1, a[\\\$1]} else {print \\\$1, \\\$1}}' - $isoformsMatrix | sed '1s/^\\t/Isoform\\tSymbol/' | paste - <(cut -f 2- $isoformsMatrix) | sed '1s/\\.isoforms\\.results//g' > $isoformsAnnotatedMatrix \n";
    # Remove "_seq" from isoform BLAST query name and keep BLAST isoform best hit as BLAST gene best hit
    $command .= "grep -v '^#' $blastResult | awk '!x[\\\$1]++' | awk -F\\\"\\t\\\" 'FNR==NR {sub(/_seq.*/, \\\"\\\", \\\$1); a[\\\$1]=\\\$2; next}{OFS=\\\"\\t\\\"; if (a[\\\$1]) {print \\\$1, a[\\\$1]} else {print \\\$1, \\\$1}}' - $genesMatrix | sed '1s/^\\t/Gene\\tSymbol/' | paste - <(cut -f 2- $genesMatrix) | sed '1s/\\.genes\\.results//g' > $genesAnnotatedMatrix \n";

    # Perform edgeR
    $command .= "Rscript \\\$R_TOOLS/edger.R -d $designFile -c $isoformsAnnotatedMatrix -o $dgeDir/isoforms_$db \n";
    $command .= "Rscript \\\$R_TOOLS/edger.R -d $designFile -c $genesAnnotatedMatrix -o $dgeDir/genes_$db \n";

    # Perform DESeq
    $command .= "Rscript \\\$R_TOOLS/deseq.R -d $designFile -c $isoformsAnnotatedMatrix -o $dgeDir/isoforms_$db \n";
    $command .= "Rscript \\\$R_TOOLS/deseq.R -d $designFile -c $genesAnnotatedMatrix -o $dgeDir/genes_$db \n";

    # Merge edgeR results with gene/isoform length values and BLAST description
    $command .= "for gi in genes isoforms; do for f in $dgeDir/\\\${gi}_$db/*/dge_results.csv; do sed '1s/gene_symbol/$db.id/' \\\$f | awk -F\\\"\\t\\\" 'FNR==NR {a[\\\$1]=\\\$2\\\"\\t\\\"\\\$3; next}{OFS=\\\"\\t\\\"; if (a[\\\$1]) {print \\\$0, a[\\\$1]} else {print \\\$0, \\\"\\\", \\\"\\\"}}' \$WORK_DIR/rsem/\\\${gi}.lengths.tsv - | sed '1s/\\t\\\$/length\\teffective_length/' | awk -F\\\"\\t\\\" 'FNR==NR {a[\\\$2]=\\\$NF; next}{OFS=\\\"\\t\\\"; if (a[\\\$2]) {print \\\$0, a[\\\$2]} else {print \\\$0, \\\"\\\"}}' <(grep -v '^#' $blastResult) - | sed '1s/\\\$/description/' > \\\${f/.csv/_$db.csv}; done; done \\\n";

    $rO_job->addCommand($command);
  }
  submitJob($rH_cfg, $step, undef, $rO_job);
}

# Merge all sample Trimmomatic results
sub metrics {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $metricsDirectory = "\$WORK_DIR/metrics";
  print "mkdir -p $metricsDirectory\n";

  my $libraryType = getParam($rH_cfg, 'default', 'libraryType');
  my $trimDirectory = "\$WORK_DIR/reads";
  my $pattern = "trim.stats.csv";
  my $outputFile = "$metricsDirectory/trimming.stats";

  # Merge all sample Trimmomatic results
  my $rO_job = Metrics::mergeTrimmomaticStats($rH_cfg, $libraryType, $pattern, $trimDirectory, $outputFile);

  $rO_job->addCommand(" && wc -l \$WORK_DIR/normalization/*.accs > $metricsDirectory/normalization.stats");

  submitJob($rH_cfg, $step, undef, $rO_job);
}

sub deliverable {
  my $rH_cfg = shift;
  my $step = shift;
  my $workDirectory = shift;

  my $rO_job = GqSeqUtils::clientReport($rH_cfg, $configFile, $workDirectory, "RNAseqDeNovo");
  submitJob($rH_cfg, $step, undef, $rO_job);
}