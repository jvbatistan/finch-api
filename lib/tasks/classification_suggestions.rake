require "set"

namespace :classification do
  def env_bool(key, default: false)
    value = ENV[key]
    return default if value.nil?

    %w[1 true yes y on].include?(value.to_s.strip.downcase)
  end

  def user_scope_for(model)
    user_id = ENV["USER_ID"].presence
    return model.all if user_id.blank?

    if model == User
      model.where(id: user_id.to_i)
    else
      model.where(user_id: user_id.to_i)
    end
  end

  def seed_ids_for(user)
    base = user.transactions.where(category_id: nil)

    single_ids = base.where(installment_group_id: nil).pluck(:id)
    grouped_ids = base.where.not(installment_group_id: nil)
                      .group(:installment_group_id)
                      .minimum(:id)
                      .values

    (single_ids + grouped_ids).uniq
  end

  desc "Gera sugestões faltantes (1 por transação avulsa, 1 por grupo parcelado). DRY_RUN=true por padrão."
  task seed_missing: :environment do
    dry_run = env_bool("DRY_RUN", default: true)
    users = user_scope_for(User)

    puts "== classification:seed_missing =="
    puts "DRY_RUN=#{dry_run} USER_ID=#{ENV['USER_ID'] || 'ALL'}"

    stats = {
      seeds: 0,
      already_pending: 0,
      auto_categorized: 0,
      suggestions_created: 0,
      errors: 0
    }

    users.find_each do |user|
      seed_ids_for(user).each do |tx_id|
        tx = Transaction.find_by(id: tx_id, user_id: user.id)
        next if tx.nil?

        stats[:seeds] += 1

        if tx.classification_suggestions.pending.exists?
          stats[:already_pending] += 1
          next
        end

        if tx.installment_group_id.present?
          group_pending = ClassificationSuggestion.pending
            .joins(:financial_transaction)
            .where(transactions: { user_id: user.id, installment_group_id: tx.installment_group_id })
            .exists?

          if group_pending
            stats[:already_pending] += 1
            next
          end
        end

        if dry_run
          next
        end

        begin
          before_category = tx.category_id
          result = Transactions::CreateCategorySuggestionService.new(tx).call
          tx.reload

          if before_category.nil? && tx.category_id.present?
            stats[:auto_categorized] += 1
          elsif result.present?
            stats[:suggestions_created] += 1
          end
        rescue StandardError => e
          stats[:errors] += 1
          puts "ERRO tx=#{tx.id}: #{e.class}"
        end
      end
    end

    puts "Seeds analisados: #{stats[:seeds]}"
    puts "Já tinham pendente: #{stats[:already_pending]}"
    puts "Auto-categorizadas: #{stats[:auto_categorized]}"
    puts "Sugestões criadas: #{stats[:suggestions_created]}"
    puts "Erros: #{stats[:errors]}"
  end

  desc "Aplica sugestões pendentes automaticamente por confiança. DRY_RUN=true por padrão. MIN_CONFIDENCE=0.95"
  task auto_apply_pending: :environment do
    dry_run = env_bool("DRY_RUN", default: true)
    min_confidence = ENV.fetch("MIN_CONFIDENCE", "0.95").to_f
    seed_missing_first = env_bool("SEED_MISSING", default: true)

    if seed_missing_first
      Rake::Task["classification:seed_missing"].reenable
      Rake::Task["classification:seed_missing"].invoke
    end

    scope = user_scope_for(ClassificationSuggestion).pending.includes(:financial_transaction).order(:id)

    puts "== classification:auto_apply_pending =="
    puts "DRY_RUN=#{dry_run} USER_ID=#{ENV['USER_ID'] || 'ALL'} MIN_CONFIDENCE=#{min_confidence} SEED_MISSING=#{seed_missing_first}"

    stats = {
      total_pending: scope.count,
      applied: 0,
      enriched_from_inference: 0,
      skipped_nil_category: 0,
      skipped_low_confidence: 0,
      skipped_missing_tx: 0,
      skipped_already_done: 0,
      errors: 0
    }

    processed_groups = Set.new
    processed_txs = Set.new

    scope.find_each do |suggestion|
      tx = suggestion.financial_transaction

      if tx.nil?
        stats[:skipped_missing_tx] += 1
        next
      end

      gid = tx.installment_group_id

      if gid.present? && processed_groups.include?(gid)
        stats[:skipped_already_done] += 1
        next
      end

      if gid.blank? && processed_txs.include?(tx.id)
        stats[:skipped_already_done] += 1
        next
      end

      if suggestion.suggested_category_id.blank?
        inferred = Transactions::SuggestCategoryService.new(tx).call

        if inferred&.suggested_category.present?
          suggestion.update!(
            suggested_category_id: inferred.suggested_category.id,
            confidence: inferred.confidence.to_f,
            source: inferred.source
          )
          stats[:enriched_from_inference] += 1
        else
          stats[:skipped_nil_category] += 1
          next
        end
      end

      if suggestion.confidence.to_f < min_confidence
        stats[:skipped_low_confidence] += 1
        next
      end

      if dry_run
        stats[:applied] += 1
        processed_groups << gid if gid.present?
        processed_txs << tx.id if gid.blank?
        next
      end

      begin
        Transaction.transaction do
          tx.update!(category_id: suggestion.suggested_category_id)

          if gid.present?
            Transactions::ApplyCategoryToInstallmentGroupService.new(
              transaction: tx,
              category: suggestion.suggested_category
            ).call

            tx_ids = tx.user.transactions.where(installment_group_id: gid).pluck(:id)
            now = Time.current
            tx.user.classification_suggestions.where(
              financial_transaction_id: tx_ids,
              accepted_at: nil,
              rejected_at: nil
            ).update_all(accepted_at: now, updated_at: now)
          else
            suggestion.update!(accepted_at: Time.current)
          end
        end

        stats[:applied] += 1
        processed_groups << gid if gid.present?
        processed_txs << tx.id if gid.blank?
      rescue StandardError => e
        stats[:errors] += 1
        puts "ERRO suggestion=#{suggestion.id} tx=#{tx.id}: #{e.class}"
      end
    end

    puts "Pendentes analisadas: #{stats[:total_pending]}"
    puts "Aplicadas: #{stats[:applied]}"
    puts "Enriquecidas por inferência: #{stats[:enriched_from_inference]}"
    puts "Ignoradas sem categoria sugerida: #{stats[:skipped_nil_category]}"
    puts "Ignoradas por confiança: #{stats[:skipped_low_confidence]}"
    puts "Ignoradas tx ausente: #{stats[:skipped_missing_tx]}"
    puts "Ignoradas já processadas: #{stats[:skipped_already_done]}"
    puts "Erros: #{stats[:errors]}"
  end

  desc "Pipeline: seed_missing + auto_apply_pending. DRY_RUN=true por padrão."
  task auto_categorize_all: :environment do
    dry_run = env_bool("DRY_RUN", default: true)
    puts "== classification:auto_categorize_all =="
    puts "DRY_RUN=#{dry_run} USER_ID=#{ENV['USER_ID'] || 'ALL'} MIN_CONFIDENCE=#{ENV.fetch('MIN_CONFIDENCE', '0.95')}"

    Rake::Task["classification:seed_missing"].reenable
    Rake::Task["classification:seed_missing"].invoke

    Rake::Task["classification:auto_apply_pending"].reenable
    Rake::Task["classification:auto_apply_pending"].invoke
  end
end
