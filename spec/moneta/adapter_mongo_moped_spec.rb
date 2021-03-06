describe 'adapter_mongo_moped' do
  let(:t_res){ 0.1 }
  let(:min_ttl){ t_res }

  moneta_build do
    Moneta::Adapters::MongoMoped.new(db: "adapter_mongo",
                                     collection: 'moped')
  end

  moneta_specs ADAPTER_SPECS.with_each_key.with_native_expires.simplevalues_only

  it 'automatically deletes expired document' do
    store.store('key', 'val', expires: 5)

    i = 0
    query = store.instance_variable_get(:@collection).find(_id: ::BSON::Binary.new('key'))
    while i < 70 && query.first
      i += 1
      sleep 1 # Mongo needs up to 60 seconds
    end

    i.should be > 0 # Indicates that it took at least one sleep to expire
    query.count.should == 0
  end
end
