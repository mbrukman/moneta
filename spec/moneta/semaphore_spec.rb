describe "semaphore" do
  moneta_store :Memory

  it 'should have #lock' do
    mutex = Moneta::Semaphore.new(store, 'semaphore')
    mutex.lock.should be true
    mutex.locked?.should be true
    expect do
      mutex.lock
    end.to raise_error(RuntimeError)
    expect do
      mutex.try_lock
    end.to raise_error(RuntimeError)
    mutex.unlock.should be_nil
    mutex.locked?.should be false
  end

  it 'should have #enter' do
    mutex = Moneta::Semaphore.new(store, 'semaphore')
    mutex.enter.should be true
    mutex.locked?.should be true
    expect do
      mutex.enter
    end.to raise_error(RuntimeError)
    expect do
      mutex.try_enter
    end.to raise_error(RuntimeError)
    mutex.leave.should be_nil
    mutex.locked?.should be false
  end

  it 'should lock with #lock' do
    a = Moneta::Semaphore.new(store, 'semaphore')
    b = Moneta::Semaphore.new(store, 'semaphore')
    a.lock.should be true
    b.try_lock.should be false
    a.unlock.should be_nil
  end

  it 'should have lock timeout' do
    a = Moneta::Semaphore.new(store, 'semaphore')
    b = Moneta::Semaphore.new(store, 'semaphore')
    a.lock.should be true
    b.lock(1).should be false
    a.unlock.should be_nil
  end

  it 'should count concurrent accesses' do
    a = Moneta::Semaphore.new(store, 'semaphore', 2)
    b = Moneta::Semaphore.new(store, 'semaphore', 2)
    c = Moneta::Semaphore.new(store, 'semaphore', 2)
    a.synchronize do
      a.locked?.should be true
      b.synchronize do
        b.locked?.should be true
        c.try_lock.should be false
      end
    end
  end

  it 'should have #synchronize' do
    semaphore = Moneta::Semaphore.new(store, 'semaphore')
    semaphore.synchronize do
      semaphore.locked?.should be true
    end
    semaphore.locked?.should be false
  end
end
