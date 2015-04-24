# coding: utf-8
require "#{LKP_SRC}/lib/common.rb"
require "#{LKP_SRC}/lib/enumerator.rb"
require "#{LKP_SRC}/lib/stats.rb"
require "#{LKP_SRC}/lib/tests.rb"
require "#{LKP_SRC}/lib/result_root.rb"

module Compare
	ABS_WIDTH = 10
	REL_WIDTH = 10
	ERR_WIDTH = 6

	class Groups
		private

		def initialize(params)
			@params = params
			group
		end

		def calc_common_axes(axes)
			as = deepcopy(axes)
			@params[:compare_axis_keys].each { |ak| as.delete ak }
			as
		end

		def group
			map = {}
			@params[:_result_roots].each { |_rt|
				as = calc_common_axes(_rt.axes)
				as.freeze
				cg = map[as] ||= Group.new(@params, as)
				cg.add_mresult_root _rt
			}
			@compare_groups = map.values
			@compare_groups.reject! { |cg| cg._result_roots.size < 2 }
		end

		public

		attr_reader :compare_groups

		def each_group(&b)
			block_given? or return enum_for(__method__)

			@compare_groups.each &b
		end

		def each_changed_stat(&b)
			block_given? or return enum_for(__method__)

			@compare_groups.each { |g|
				g.each_changed_stat &b
			}
		end
	end

	class Group
		private

		def initialize(params, common_axes)
			@params = params
			@common_axes = common_axes
			@_result_roots = []
		end

		def calc_compare_axeses
			compare_axis_keys = @params[:compare_axis_keys]
			@_result_roots.map { |_rt|
				_rt.axes.select { |k,v| compare_axis_keys.index k }
			}
		end

		public

		attr_reader :_result_roots, :common_axes

		def add_mresult_root(_rt)
			@_result_roots << _rt
		end

		def compare_axeses
			@compare_axeses ||= calc_compare_axeses
		end

		def matrixes
			@matrixes ||= _result_roots.map { |_rt| _rt.matrix.freeze }
		end

		def complete_matrixes
			unless @complete_matrixes
				cms = _result_roots.zip(matrixes).map { |_rt, m|
					_rt.complete_matrix m
				}
				@complete_matrixes = cms
			end
			@complete_matrixes
		end

		def all_stats
			stat_keys = []
			matrixes.each { |m|
				stat_keys |= m.keys
			}
			stat_keys.delete 'stats_source'
			stat_keys
		end

		def changed_stats
			@changed_stats ||= all_stats
		end

		def calc_changed_stats
			changed_stats = []
			mfile0 = @_result_roots[0].matrix_file
			@_result_roots.drop(1).each { |_rt|
				changed_stats |= get_changed_stats(_rt.matrix_file, mfile0).keys
			}
			@changed_stats = changed_stats
		end

		def include_stats(stat_res)
			astats = all_stats
			matched = stat_res.map { |sre|
				re = Regexp.new(sre)
				astats.select { |stat| re.match stat }
			}.flatten
			@changed_stats |= matched
		end

		def each_changed_stat
			block_given? or return enum_for(__method__)

			ms = matrixes
			cms = complete_matrixes
			runs = ms.map { |m| matrix_cols m }
			cruns = cms.map { |m| matrix_cols m }
			changed_stats.each { |stat_key|
				failure = is_failure stat_key
				tms = failure ? ms : cms
				truns = failure ? runs : cruns
				stat = {
					stat_key: stat_key,
					failure: failure,
					group: self,
					values: tms.map { |m| m[stat_key] },
					runs: truns
				}
				yield stat
			}
		end
	end

	def self.calc_failure_fail(stat)
		return unless stat[:failure]
		stat[:fails] = stat[:values].map { |v|
			v ? v.sum : 0
		}
	end

	def self.calc_failure_change(stat)
		return unless stat[:failure]
		fs = stat[:fails]
		runs = stat[:runs]
		reproduce0 = fs[0].to_f / runs[0]
		stat[:changes] = fs.drop(1).each_with_index.map { |f, i|
			100 * (f.to_f / runs[i] - reproduce0)
		}
	end

	def self.calc_avg_stddev(stat)
		return if stat[:failure]
		vs = stat[:values]
		stat[:avgs] = vs.map { |v| v ? v.average : 0 }
		stat[:stddevs] = vs.map { |v| v.standard_deviation if v && v.size > 1 }
	end

	def self.calc_perf_change(stat)
		return if stat[:failure]
		avgs = stat[:avgs]
		avg0 = avgs[0]
		stat[:changes] = avgs.drop(1).map { |avg|
			100.0 * (avg - avg0) / avg0
		}
	end

	def self.calc_stat_change(stat)
		calc_failure_fail stat
		calc_failure_change stat
		calc_avg_stddev stat
		calc_perf_change stat
	end

	def self.sort_stats(stat_enum)
		stats = stat_enum.to_a
		stat_base_map = {}
		stats.each { |stat|
			base = stat_key_base stat[:stat_key]
			stat[:stat_base] = base
			stat_base_map[base] ||= stat[:failure] ? -10000 : 0
			stat_base_map[base] += 1
		}
		AllTests.each { |test|
			c = stat_base_map[test]
			if c and c > 0
				stat_base_map[test] = 0
			end
		}
		stats.sort_by! { |stat| [stat_base_map[stat[:stat_base]], stat[:stat_key]] }
		stats.each
	end

	def self.show_failure_change(stat)
		return unless stat[:failure]
		fails = stat[:fails]
		changes = stat[:changes]
		runs = stat[:runs]
		fails.each_with_index { |f, i|
			unless i == 0
				printf "%#{REL_WIDTH}.0f%% ", changes[i-1]
			end
			if f == 0
				printf "%#{ABS_WIDTH+1}s", ' '
			else
				printf "%#{ABS_WIDTH+1}d", f
			end
			printf ":%-#{ERR_WIDTH-2}d", runs[i]
		}
	end

	def self.show_perf_change(stat)
		return if stat[:failure]
		avgs = stat[:avgs]
		stddevs = stat[:stddevs]
		changes = stat[:changes]
		avgs.each_with_index { |avg, i|
			unless i == 0
				p = changes[i-1]
				fmt = p.abs < 100000 ? '.1f' : '.2g'
				printf "%+#{REL_WIDTH}#{fmt}%% ", p
			end
			if avg.abs < 1000
				fmt = '.2f'
			elsif avg.abs > 100000000
				fmt = '.4g'
			else
				fmt = 'd'
			end
			printf "%#{ABS_WIDTH}#{fmt}", avg
			stddev = stddevs[i]
			if stddev
				stddev = 100 * stddev / avg if avg != 0
				printf " ±%#{ERR_WIDTH-3}d%%", stddev
			else
				printf " " * ERR_WIDTH
			end
		}
	end

	def self.show_stat(stat)
		printf "  %s\n", stat[:stat_key]
	end

	def self.show_group_header(group)
		common_axes = group.common_axes
		compare_axeses = group.compare_axeses
		puts "========================================================================================="
		printf "%s:\n", common_axes.keys.join('/')
		printf "  %s\n\n", common_axes.values.join('/')
		printf "%s: \n", compare_axeses[0].keys.join('/')
		compare_axeses.each { |compare_axes|
			printf "  %s\n", compare_axes.values.join('/')
		}
		puts
		first_width = ABS_WIDTH + ERR_WIDTH
		width = first_width + REL_WIDTH
		printf "%#{first_width}s ", compare_axeses[0].values.join('/')[0...first_width]
		compare_axeses.drop(1).each { |compare_axes|
			printf "%#{width}s ", compare_axes.values.join('/')[0...width]
		}
		puts
		printf "-" * first_width + ' '
		compare_axeses.drop(1).size.times {
			printf "-" * width + ' '
		}
		puts
	end

	def self.show_perf_header(n = 1)
		# (ABS_WIDTH + ERR_WIDTH)   (2 + REL_WIDTH + ABS_WIDTH + ERR_WIDTH)
		#      |<-------------->|   |<--------------------------->|
		printf '         %%stddev' + '     %%change         %%stddev' * n + "\n"
		printf '             \  ' + '        |                \  ' * n + "\n"
	end

	def self.show_failure_header(n = 1)
		printf '       fail:runs' + '  %%reproduction    fail:runs' * n + "\n"
		printf '           |    ' + '         |             |    ' * n + "\n"
	end

	def self.show_group(group, stat_enum)
		nr_header = group._result_roots.size - 1
		failure, perf = stat_enum.partition { |stat| stat[:failure] }
		show_group_header group

		unless failure.empty?
			show_failure_header(nr_header)
			failure.each { |stat|
				show_failure_change stat
				show_stat stat
			}
		end

		unless perf.empty?
			show_perf_header(nr_header)
			perf.each { |stat|
				show_perf_change stat
				show_stat stat
			}
		end

		puts
	end

	def self.show_by_group(groups, stat_enums)
		groups.each_group.with_index { |g, i|
			show_group g, stat_enums[i]
		}
	end

	def self.group_by_stat(stat_enum)
		stat_map = {}
		stat_enum.each { |stat|
			key = stat[:stat_key]
			stat_map[key] ||= []
			stat_map[key] << stat
		}
		stat_map
	end

	def self.show_by_stats(groups, stat_enums)
		stat_enum = EnumeratorCollection.new(*stat_enums)
		stat_map = group_by_stat(stat_enum)
		stat_map.each { |stat_key, stats|
			puts "#{stat_key}:"
			stats.each { |stat|
				if stat[:failure]
					show_failure_change stat
				else
					show_perf_change stat
				end
				printf "  %s\n", stat[:group].common_axes.values.join('/')
			}
		}
	end

	def self.compare(params)
		groups = Groups.new(params)

		groups.each_group { |g|
			unless params[:show_all_stats]
				g.calc_changed_stats
				include_stats = params[:include_stats]
				if include_stats
					g.include_stats(include_stats)
				end
			end
		}

		stat_enums = groups.each_group.map { |g|
			stat_enum = g.each_changed_stat.feach(method(:calc_stat_change))
			unless params[:group_by_stat]
				sort_stats stat_enum
			end
		}

		if params[:group_by_stat]
			show_by_stats(groups, stat_enums)
		else
			show_by_group(groups, stat_enums)
		end
	end

	def self.compare_commits(commits, params_in = {})
		# calc compare groups
		# calc change stats
		# calc stat change
		# group result
		# output
		_result_roots = commits.map { |c| MResultRootCollection.new('commit' => c).to_a }.flatten
		compare_axis_keys = ['commit']
		params = {
			_result_roots: _result_roots,
			compare_axis_keys: compare_axis_keys
		}.merge(params_in)
		compare(params)
	end

	def self.test_compare_commits
		commits = ['f5c0a122800c301eecef93275b0c5d58bb4c15d9', '3a8b36f378060d20062a0918e99fae39ff077bf0']
		compare_axis_keys = ['commit', 'rwmode']
		page {
			#compare_commits(commits, show_all_stats: true, group_by_stat: true)
			compare_commits(commits, show_all_stats: false, group_by_stat: false,
					compare_axis_keys: compare_axis_keys)
		}
	end

	def self.test_incomplete_run
		_rt_ = '/result/lkp-sb02/fileio/performance-600s-100%-1HDD-ext4-64G-1024f-seqrd-sync/debian-x86_64-2015-02-07.cgz/x86_64-rhel/'
		rts_ = ['9eccca0843205f87c00404b663188b88eb248051', '06e5801b8cb3fc057d88cb4dc03c0b64b2744cda'].
			     map { |c| MResultRoot.new(_rt_ + c) }
		rts_.each { |_rt|
			puts "#{_rt.runs}"
		}
		params = {
			_result_roots: rts_,
			compare_axis_keys: ['commit'],
			show_all_stats: false,
		}
		page {
			compare(params)
		}
	end
end