module Jobs
  class InspectToxicPost < Jobs::Scheduled
    every 10.minutes

    BATCH_SIZE = 1000
    LAST_CHECKED_POST_ID_KEY = 'last_checked_post_id'
    LAST_CHECKED_TIME_KEY = 'last_checked_iteration_timestamp'
    FAILED_POST_ID_KEY = 'failed_post_ids'

    def store
      @store ||= PluginStore.new('discourse-etiquette')
    end

    def last_checked_post_id
      store.get(LAST_CHECKED_POST_ID_KEY)&.to_i
    end

    def last_checked_post_id=(val)
      store.set(LAST_CHECKED_TIME_KEY, DateTime.now)
      store.set(LAST_CHECKED_POST_ID_KEY, val)
    end

    def last_checked_post_timestamp
      store.get(LAST_CHECKED_TIME_KEY)&.to_datetime || 100.years.ago
    end

    def execute(args)
      return unless SiteSetting.etiquette_enabled? && SiteSetting.etiquette_backfill_posts

      p "retry"
      batch_size = retry_failed_checks(BATCH_SIZE)
      p "check"
      check_posts(batch_size)
    end

    def retry_failed_checks(batch_size)
      return if batch_size <= 0
      failed_post_ids = (store.get(FAILED_POST_ID_KEY) || [])

      queued_post = failed_post_ids[0...batch_size]
      success_checks = 0
      unless queued_post.empty?
        queued = Set.new(queued_post)
        checked = Set.new

        queued_post.each do |p|
          p "checking failed #{p}"
          p = Post.find_by(id: p)
          if p.nil?
            checked.add(p.id)
            next
          end

          if DiscourseEtiquette.should_check_post?(p)
            begin
              DiscourseEtiquette.backfill_post_etiquette_check(p)
              checked.add(p.id)
            rescue
              next
            end
          else
            checked.add(p.id)
          end
        end

        success_checks = checked.size
        store.set(FAILED_POST_ID_KEY, (Set.new(failed_post_ids[batch_size..-1]) + queued - checked).to_a)
      end

      return batch_size - success_checks
    end

    def check_posts(batch_size)
      return if batch_size <= 0
      queued = Set.new
      checked = Set.new
      last_id = last_checked_post_id
      Post.order(id: :asc).includes(:topic).offset(last_checked_post_id).limit(batch_size).find_each do |p|
        p "checking #{p.id}"
        queued.add(p.id)
        last_id = p.id
        if DiscourseEtiquette.should_check_post?(p)
          begin
            DiscourseEtiquette.backfill_post_etiquette_check(p)
            checked.add(p.id)
          rescue
            next
          end
        end
      end

      last_checked_post_id = last_id
      failed_post_ids = (queued - checked)
      unless failed_post_ids.empty?
        failed_post_ids = failed_post_ids + Set.new(store.get(FAILED_POST_ID_KEY))
        store.set(FAILED_POST_ID_KEY, failed_post_ids.to_a)
      end

      try_start_new_iteration if finish_last_iteration?(last_checked_post_id)
    end

    def finish_last_iteration?(last_checked_post_id)
      if last_checked_post_timestamp + SiteSetting.etiquette_historical_inspection_period > DateTime.now &&
          last_checked_post_id >= Post.order(id: :asc).pluck(:id).last
        last_checked_post_timestamp = DateTime.now
        last_checked_post_id = 0
      end
    end
  end
end
