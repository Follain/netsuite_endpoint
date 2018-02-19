module NetsuiteIntegration
  class GlJournal < Base
    attr_reader :config, :payload, :ns_journal,:journal_payload,:journal

    def initialize(config, payload = {})
        super(config, payload)
        @config = config

        @journal_payload=payload[:gl_journal]
        create_journal
    end

    def find_journal_by_external_id(journal_id)
        NetSuite::Records::JournalEntry.get(external_id: journal_id)
        # Silence the error
        # We don't care that the record was not found
        rescue NetSuite::RecordNotFound
    end

    def new_journal?
        new_journal ||= !find_journal_by_external_id(journal_id)
    end

    def journal_id
        @journal_id  ||=journal_payload['journal_id'].to_s
    end

    def ns_id
        @ns_id ||=journal_payload['id']
    end

    def journal_date
        @journal_date ||=journal_payload['journal_date']
    end

    def journal_memo
        @journal_memo ||=journal_payload['journal_memo']
    end

    def glrules
        @glrules=journal_payload[:glrules]
    end

    def journal_location
        @journal_location ||=journal_payload['journal_location']
    end

    def journal_subsidiary
        @journal_subsidiary ||=journal_payload['glrules']['subsidiary']
    end

    def load_transactioncodes
        #TransactionCode.add :spreesale, amtcol: :sale, debit_acct: {val: 345}, credit_acct: {map: :ptype}, debit_dept: {map: :location},credit_dept: {map: :location}, memo: {desc: :memo}
        glrules[:transactioncodes].map do |codes|
            codes[:columns].map do |columns|
            TransactionCode.add codes['name'].to_sym, amtcol: columns['name'].to_sym, debit_acct: columns['debit_acct'], credit_acct: columns['credit_acct'], debit_dept: columns['debit_dept'],credit_dept: columns['credit_dept'], memo: columns['memo']
            end
        end
    end

    def load_maps
        #add :cctype_giftcard, acct: 744, dept: nil
        glrules[:lookupmaps].map do |maps|
            TransactionLookupMap.add maps['name'].to_sym, acct: maps['acct'], dept: maps['dept']
            end
    end

    def build_item_list
        @journal_items=[]
        journal_payload[:line_items].map do |item|
        @journal_items << TransactionJournals.generate(item['journal_type'].to_sym,item)
        end
        NetSuite::Records::JournalEntryLineList.new(replace_all: true, line: @journal_items.flatten.compact)
    end

    def create_journal
        if new_journal?
            #only load maps once else it will result in recursion (esp when running in-line)
            if TransactionCode.transactions.empty?
                load_transactioncodes
            end
            if TransactionLookupMap.lookupmaps.empty?
                load_maps
            end
           @journal=NetSuite::Records::JournalEntry.new
            journal.external_id=journal_id
            journal.memo=journal_memo
            journal.tran_date=NetSuite::Utilities.normalize_time_to_netsuite_date(journal_date.to_datetime)
            journal.location={internal_id: journal_location}
            journal.line_list=build_item_list
            if journal.line_list.lines.any?
                journal.subsidiary={internal_id: journal_subsidiary}
                journal.add
                if journal.errors.any?{|e| "WARN" != e.type}
                    raise "journal create failed: #{journal.errors.map(&:message)}"
                end
            end
            line_item = { journal_id: journal_id, netsuite_id: journal.internal_id, description: journal_memo,type: 'journal' }
            ExternalReference.record :gl_journal, journal_id, { netsuite: line_item }, netsuite_id: journal.internal_id
        end
    end

 end
end