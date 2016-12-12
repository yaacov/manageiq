module Metric::LongTermAverages
  LIVE_PERF_SUPPORTED_OBJ = %w(ContainerNode ContainerGroup Container ContainerProject ContainerManager).freeze
  LIVE_PERF_TAG = '/managed/live_reports/use_hawkular'.freeze

  AVG_COLS_TO_OVERHEAD_TYPE = {
    :cpu_usagemhz_rate_average      => nil,
    :derived_memory_used            => nil,
    :max_cpu_usage_rate_average     => :cpu,
    :max_mem_usage_absolute_average => :memory
  }
  AVG_COLS = AVG_COLS_TO_OVERHEAD_TYPE.keys

  AVG_METHODS_INFO = {}
  AVG_METHODS_WITHOUT_OVERHEAD_INFO = {}
  AVG_COLS.product([:avg, :low, :high]).each do |col, type|
    meth = :"#{col}_#{type}_over_time_period"
    AVG_METHODS_INFO[meth] = {
      :column => col,
      :type   => type
    }
    unless AVG_COLS_TO_OVERHEAD_TYPE[col].nil?
      AVG_METHODS_WITHOUT_OVERHEAD_INFO[:"#{meth}_without_overhead"] = {
        :column        => col,
        :type          => type,
        :base_meth     => meth,
        :overhead_type => AVG_COLS_TO_OVERHEAD_TYPE[col]
      }
    end
  end

  AVG_METHODS = AVG_METHODS_INFO.keys
  AVG_METHODS_WITHOUT_OVERHEAD = AVG_METHODS_WITHOUT_OVERHEAD_INFO.keys

  AVG_DAYS = 30

  def self.get_class_name(obj)
    obj.class.name.split('::').last
  end

  def self.get_field_value(record, field)
    if record.kind_of?(Hash)
      record[field]
    else
      record.send(field)
    end
  end

  def self.live_report?(obj)
    class_name = get_class_name(obj) if obj
    ems = if class_name == "ContainerManager"
            obj
          elsif obj.try(:ems_id)
            ExtManagementSystem.find(obj.ems_id)
          end

    ems && ems.tags.exists?(:name => LIVE_PERF_TAG) && LIVE_PERF_SUPPORTED_OBJ.include?(class_name)
  end

  def self.get_averages_over_time_period(obj, options = {})
    results = {:avg => {}, :dev => {}}
    vals = {}
    counts = {}
    ext_options = options.delete(:ext_options) || {}
    tz = Metric::Helper.get_time_zone(ext_options)
    avg_days = options[:avg_days] || AVG_DAYS
    avg_cols = options[:avg_cols] || AVG_COLS

    ext_options = ext_options.merge(:only_cols => avg_cols)
    perfs = if live_report?(obj)
              VimPerformanceAnalysis.live_perf_for_time_period(
                obj, "daily", :end_date => Time.now.utc, :days => avg_days, :ext_options => ext_options
              ) || []
            else
              VimPerformanceAnalysis.find_perf_for_time_period(
                obj, "daily", :end_date => Time.now.utc, :days => avg_days, :ext_options => ext_options
              )
            end

    perfs.each do |p|
      if ext_options[:time_profile] && !ext_options[:time_profile].ts_day_in_profile?(p.timestamp.in_time_zone(tz))
        next
      end

      avg_cols.each do |c|
        vals[c] ||= []
        results[:avg][c] ||= 0
        counts[c] ||= 0

        val = get_field_value(p, c) || 0
        vals[c] << val
        val *= 1.0 unless val.nil?
        Metric::Aggregation::Aggregate.average(c, self, results[:avg], counts, val)
      end
    end

    results[:avg].each_key do |c|
      Metric::Aggregation::Process.average(c, nil, results[:avg], counts)

      begin
        results[:dev][c] = vals[c].length == 1 ? 0 : vals[c].stddev
        raise StandardError, "result was NaN" if results[:dev][c].try(:nan?)
      rescue => err
        _log.warn("Unable to calculate standard deviation, '#{err.message}', values: #{vals[c].inspect}")
        results[:dev][c] = 0
      end
    end

    results
  end
end
