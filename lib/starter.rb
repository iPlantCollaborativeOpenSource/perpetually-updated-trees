#!/usr/bin/env ruby


# code import
require 'rraxml'
require 'rnewick'
require 'rphylip'
require 'perpetual_evaluation'

# gems
require 'logger'   

class TreeBunchStarter 
  # Given an initial alignment, it creates a initial bunch of ML trees in bunch_0 dir
  # should log results
  attr_reader :bestML_trees_dir

  def initialize(opts)
    @phylip = opts[:phylip]
    @partition_file = opts[:partition_file]
    @base_dir = opts[:base_dir]
    @prev_dir = opts[:prev_dir]
    @update_id = opts[:update_id] || 0
    @num_threads = opts[:num_threads] || 0 
    # create dirs if required
    @alignment_dir = File.join @base_dir, "alignments"
    @parsimony_trees_dir = File.join @base_dir, "parsimony_trees"
    @parsimony_trees_out_dir = File.join @parsimony_trees_dir, "output"
    @ml_trees_dir = File.join @base_dir, "ml_trees"
    # the new phylip
    @phylip_updated = File.join @alignment_dir, "phy_#{@update_id.to_s}"

    # defaults, in general will be overriden when calling start_iteration
    @num_parsi_trees = 4 
    @num_bestML_trees = @num_parsi_trees / 2 
    #  

    # if it is an update this info is already in opts[]
    @CAT_topology_bunch = File.join @ml_trees_dir, "CAT_topology_bunch.nw"
    @CAT_topology_bunch_order = File.join @ml_trees_dir, "CAT_topology_bunch_order.txt"

    cnf = opts[:conf] 
    @iteration_results_name = cnf['iteration_results_name']
    @bestML_trees_dir = File.join @base_dir, cnf['best_ml_folder_name']
    @bestML_bunch = File.join @bestML_trees_dir, cnf['best_ml_bunch_name']
    @prev_bestML_bunch = File.join @prev_dir, cnf['best_ml_folder_name'], cnf['best_ml_bunch_name'] unless @prev_dir.nil?
    # logging locally
    #@logpath = File.join @base_dir, cnf['iteration_log_name']
    @logpath = cnf['iteration_log_name']
  end
  def logput(msg, error = false)
    @logger ||= Logger.new(@logpath)
    if error
      @logger.error msg
      puts msg.red
    else
      @logger.info msg
      puts msg
    end
  end
  def logputgreen(msg)
    @logger ||= Logger.new(@logpath)
    @logger.info msg
    puts msg.green
  end
  def ready?
    ready = true
    dirs = [@alignment_dir, @parsimony_trees_dir, @parsimony_trees_out_dir,@ml_trees_dir, @bestML_trees_dir]
    dirs.each do |d|
      if not File.exist?(d)
        FileUtils.mkdir_p d
        logput "Created " + pumper_path(d)
      else
        logput "Exists " + pumper_path(d)
        ready = false
      end
    end
    if @update_id == 0
      FileUtils.cp @phylip, @alignment_dir 
    else
      logput "Copying new update alignment (not expanding) from #{@phylip} to #{@phylip_updated}"
      FileUtils.cp @phylip, @phylip_updated 
    end
    FileUtils.cp @partition_file, @alignment_dir if File.exist? @partition_file
    ready
  end
  def start_iteration(opts)
    logput "Preparing new iteration..."
    check_options(opts)
    begin
      num_parsi_trees = opts[:num_parsi_trees] || @num_parsi_trees
      num_bestML_trees = opts[:num_bestML_trees] || @num_bestML_trees
      if opts[:initial_iteration]
        logputgreen "Initial iteration"
        num_iteration_trees = num_parsi_trees
        logput "#{num_iteration_trees} ML trees will be generated from #{num_parsi_trees} new parsimony trees"
        phylip_dataset = @phylip
        @update_id = 0
      else
        logputgreen "Update iteration"
        logput "Looking for parsimony start trees from previous bunch\n----"
        phylip_dataset = @phylip_updated
        raise "prev bunch not ready #{@prev_bestML_bunch}" unless File.exist?(@prev_bestML_bunch)
        last_best_bunch = PerpetualNewick::NewickFile.new(@prev_bestML_bunch)
        last_best_bunch.save_each_newick_as(File.join(@parsimony_trees_dir, 'prev_parsi_tree'), "nw") 
        prev_trees = Dir.entries(@parsimony_trees_dir).select{|f| f =~ /^prev_parsi_tree/}
        prev_trees_paths = prev_trees.map{|f| File.join @parsimony_trees_dir, f}
        num_iteration_trees = num_parsi_trees * prev_trees.size
        logput "#{prev_trees.size} initial trees available from previous iteration"
        logput "#{num_iteration_trees} ML trees will be generated, based on #{num_parsi_trees} new parsimony trees from each #{prev_trees.size} previous tree"
      end
      if num_bestML_trees > num_iteration_trees 
        raise "#bestML trees (#{num_bestML_trees}) cant be higher than iteration number of trees #{num_iteration_trees}"
      end
      logputgreen "****** Start iteration no #{@update_id} ********"
      logputgreen "step 1 of 2 : Compute #{num_parsi_trees} Parsimony starting trees\n----"
      if opts[:initial_iteration]
        generate_parsimony_trees(num_parsi_trees)
        parsimony_trees_dir = @parsimony_trees_dir
      else
        update_parsimony_trees(num_parsi_trees, prev_trees)
        parsimony_trees_dir = @parsimony_trees_out_dir
      end
      logputgreen "step 2 of 2 : Compute #{num_iteration_trees} ML trees and select the #{num_bestML_trees} best\n----"
      best_lh = generate_ML_trees(parsimony_trees_dir, phylip_dataset, num_bestML_trees, @partition_file)
      logputgreen "****** Finished iteration no #{@update_id} ********"
      logput "Bunch of #{num_bestML_trees} ML trees ready at #{@bestML_bunch}\n----"
      best_lh
    rescue Exception => e
      logput(e.to_s, error = true)
      raise e
    end
  end
  def search_std(num_gamma_trees = nil)
    search_opts = {
      :phylip => @phylip,
      :partition_file => @partition_file,
      :outdir => @ml_trees_dir,
      :num_gamma_trees => num_gamma_trees || 1, 
      :stderr => File.join(@ml_trees_dir, "err"),
      :stdout => File.join(@ml_trees_dir, "info"),
      :name => "std_GAMMA_search" 
    }
    search_opts.merge!({:num_threads => @num_threads}) if @num_threads.to_i > 0
    r = RaxmlGammaSearch.new(search_opts)
    logput "Start ML search from scratch with #{num_gamma_trees} trees"
    r.run
    bestLH = File.open(r.stdout).readlines.find{|l| l =~ /^Final GAMMA-based Score of best/}.chomp.split("tree").last
    logput "Done ML search from scratch with #{num_gamma_trees} trees"
    bestLH
  end
  private
  def check_options(opts)
    supported_opts = [:num_parsi_trees, :num_bestML_trees, :exp_name, :cycle_batch_script, :initial_iteration]
    opts.keys.each do |key|
      unless supported_opts.include?(key)
        logput "Option #{key} is unknwon"
      end
    end
  end
  def generate_parsimony_trees(num_parsi_trees)
    logput "Preparing parsimony runs for #{num_parsi_trees} trees" 
    logput "Results stored in #{pumper_path(@parsimony_trees_dir)}" 
    num_parsi_trees.times do |i|
      seed = i + 123  # this is arbitrary, could be a random number
      parsimonator_opts = {
        :phylip => @phylip,
        :num_trees => 1,
        :seed => seed,
        :outdir => @parsimony_trees_dir,
        :stderr => File.join(@parsimony_trees_dir, "err_treeno#{i}"),
        :stdout => File.join(@parsimony_trees_dir, "info_treeno#{i}"),
        :name => "parsimony_initial_s#{seed}"
      }
      parsi = PerpetualTreeMaker::Parsimonator.new(parsimonator_opts)  
      logput "\nComputing parsimony tree #{i+1}/#{num_parsi_trees} for the initial iteration"
      parsi.run(@logger)
    end
    logput "Done with parsimony trees of initial bunch"
  end
  def update_parsimony_trees(num_parsi_trees, trees)
    trees.each_with_index do |parsi_start_tree, i|
      logput "Starting new parsimony tree with #{parsi_start_tree} trees" 
      parsimonator_opts = {
        :phylip => @phylip_updated,
        :num_trees => num_parsi_trees,
        :newick => File.join(@parsimony_trees_dir, parsi_start_tree),
        :outdir => @parsimony_trees_out_dir,
        :stderr => File.join(@parsimony_trees_out_dir, "err_#{parsi_start_tree}"),
        :stdout => File.join(@parsimony_trees_out_dir, "info_#{parsi_start_tree}"),
        :name => "u#{@update_id}_#{parsi_start_tree}"
      }
      parsi =PerpetualTreeMaker::Parsimonator.new(parsimonator_opts)  
      logput "Start computing parsimony trees of #{parsi_start_tree}, #{i+1} of #{trees.size}"
      parsi.run
      logput "run with options #{parsi.ops.to_s}"
      logput "Done with parsimony trees of #{parsi_start_tree}, #{i+1} of #{trees.size}"
    end 
  end
  def generate_ML_trees(starting_trees_dir, phylip, num_bestML_trees, partition_file)
    starting_trees = Dir.entries(starting_trees_dir).select{|f| f =~ /^RAxML_parsimonyTree/}
    raise "no starting trees available" if starting_trees.nil? or starting_trees.size < 1
    logput "LOCAL: #{starting_trees.size} starting trees to be used"
    gamma_trees = []
    starting_trees.each_with_index do |parsimony_tree, i|
      # Run pipeline locally
      # Search with raxml light
      tree_id = parsimony_tree.split("parsimonyTree.").last
      light_opts = {
        :phylip => phylip,
        :partition_file => partition_file,
        :outdir => @ml_trees_dir,
        :flags => " -D ", # default to a RF convergence criterion
        :starting_newick => File.join(starting_trees_dir, parsimony_tree),
        :stderr => File.join(@ml_trees_dir, "err#{tree_id}"),
        :stdout => File.join(@ml_trees_dir, "info#{tree_id}"),
        :name => "starting_parsimony_tree_" + tree_id
      }
      light_opts.merge!({:num_threads => @num_threads}) if @num_threads.to_i > 0
      r = PerpetualTreeMaker::RaxmlLight.new(light_opts)
      logput "Start ML search for #{parsimony_tree} (#{i+1} of #{starting_trees.size})"
      r.run
      #logput "Done ML search for #{parsimony_tree} (#{i+1} of #{starting_trees.size})"

      # Score under GAMMA and compute local support after finding the best NNI tree 
      nni_starting_tree =  File.join(r.outdir, "RAxML_result.#{r.name}")
      logput "Scoring tree #{nni_starting_tree}"
      scorer_opts = {
        :phylip => phylip,
        :partition_file => partition_file,
        :outdir => @ml_trees_dir,
        :starting_newick => nni_starting_tree,
        :stderr => File.join(@ml_trees_dir, "err_score_#{tree_id}"),
        :stdout => File.join(@ml_trees_dir, "info_score_#{tree_id}"),
        :name => "SCORING_#{tree_id}"
      }
      scorer_opts.merge!({:num_threads => @num_threads}) if @num_threads.to_i > 0
      scorer = PerpetualTreeMaker::RaxmlGammaScorer.new(scorer_opts)
      scorer.run
      final_lh = scorer.finalLH(File.join scorer.outdir, "RAxML_info.#{scorer.name}")
      logput "Score for tree #{nni_starting_tree}: #{final_lh}"
    end
    # Get the best trees
    iteration_args = [@bestML_bunch, num_bestML_trees, "", @update_id, @ml_trees_dir, @iteration_results_name]
    iteration = PerpetualTreeEvaluation::IterationFinisher.new iteration_args
    iteration_results = PerpetualTreeEvaluation::ProjectResults.new :info_files_dir => iteration.results_dir, 
      :best_set => num_bestML_trees,
      :expected_set => starting_trees.size
    logput "#{iteration_results.lh_rank.to_s}"
    iteration.add_best_trees(iteration_results.lh_rank)
    iteration.add_finish_label
    iteration_results.lh_rank.first[:lh]
  end
end
