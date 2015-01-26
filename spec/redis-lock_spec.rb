require 'spec_helper'

describe Redis::Lock do
  subject       { Redis::Lock.new(key, options) }
  let(:key)     { 'key' }

  context 'when the timeout is less then the expiration' do
    let(:options) { { :timeout => 1, :expire => 1.5 } }

    context 'using lock/unlock' do
      it "can lock and unlock" do
        subject.lock

        subject.try_lock.should == false

        subject.try_unlock.should == true

        subject.try_lock.should == true
      end

      it "blocks if a lock is taken for the duration of the timeout" do
        subject.lock
        unlocked = false

        Thread.new { subject.lock rescue nil; unlocked = true }

        unlocked.should == false

        sleep 2

        unlocked.should == true
      end

      it "expires the lock after the lock timeout" do
        subject.lock

        subject.try_lock.should == false
        sleep 2

        subject.try_lock.should == :recovered
      end

      it "raises if trying to unlock a lock that has been recovered" do
        subject.lock

        sleep 2
        Redis::Lock.new(key, options).try_lock

        expect { subject.unlock }.to raise_error(Redis::Lock::LostLock)
      end

      it "can extend the lock" do
        subject.lock

        subject.try_lock.should == false

        sleep 2
        subject.try_extend.should == true

        subject.try_lock.should == false
      end

      it "will not extend the lock if taken by another instance" do
        subject.lock

        subject.try_lock.should == false

        sleep 2
        Redis::Lock.new(key, options).try_extend.should == false

        subject.try_lock.should == :recovered
      end

      it 'raises if the lock is taken' do
        subject.lock

        expect { subject.lock }.to raise_error(Redis::Lock::Timeout)
      end
    end

    context 'using synchronize' do
      it "can lock" do
        subject.synchronize do
          subject.try_lock.should == false
        end
        subject.try_lock.should == true
      end

      it "ensures that the lock is unlocked when locking with a block" do
        begin
          subject.synchronize do
            raise "An error"
          end
        rescue
        end

        subject.try_lock.should == true
      end

      it "does not run the critical section if the lock times out" do
        subject.lock

        critical = false

        expect { subject.synchronize { critical = true } }.to raise_error(Redis::Lock::Timeout)

        critical.should == false
      end

      it "returns the value returned by the block" do
        subject.synchronize { 'a' }.should == 'a'
      end

      context 'when the expiration time is less then the timeout' do
        let(:options) { { :timeout => 1.5, :expire => 1 } }

        it "does not raise when the lock is recovered" do
          subject.lock
          expect { Redis::Lock.new(subject.key, options).synchronize {}  }.to_not raise_error
        end
      end
    end
  end

  context 'when passing in recovery data with a lock' do
    subject       { Redis::Lock.new(key, options) }
    let(:options) { { :timeout => 1, :expire => 0 } }

    context "when data is not a string" do
      let(:data) { { :a => 1 } }

      it "raises" do
        expect { subject.lock(:recovery_data => data) }.to raise_error
      end
    end

    context "when an expired lock is re-locked" do
      let(:data)    { "some data" }
      let(:options) { { :timeout => 1, :expire => 0.0 } }

      before do
        subject.lock(:recovery_data => data)
        sleep 1
      end

      it "raises and does not overwrite the data" do
        2.times do
          begin
            lock = Redis::Lock.new(subject.key, options)
            lock.lock(:recovery_data => "other data")
          rescue Redis::Lock::Recovered
            lock.recovery_data.should == data
          end
        end
      end
    end
  end
end

describe Redis::Lock, '#expired' do
  context "when there are no expired locks" do
    it "returns an empty array" do
      Redis::Lock.expired.should be_empty
    end
  end

  context "when there are expired locks and unexpired locks" do
    let(:expired)   { Redis::Lock.new('1', { :expire => 0,    :key_group => key_group }) }
    let(:unexpired) { Redis::Lock.new('2', { :expire => 100,  :key_group => key_group }) }
    let(:key_group) { 'test' }

    before do
      expired.lock
      unexpired.lock
      sleep 1
    end

    it "returns all locks that are expired" do
      Redis::Lock.expired(:key_group => key_group).should == [expired]
    end

    it "only returns locks for the current key_group" do
      Redis::Lock.expired(:key_group => 'xxx').should be_empty
    end

    it "removes the key when locking then recovering an expired lock" do
      lock = Redis::Lock.expired(:key_group => key_group).first

      lock.unlock

      Redis::Lock.expired(:key_group => key_group).should be_empty
    end

    it "is possible to extend a lock returned and only allow a recovered lock to be extended once" do
      lock1 = Redis::Lock.expired(:key_group => key_group).first
      lock2 = Redis::Lock.expired(:key_group => key_group).first

      lock1.try_extend.should == true
      lock2.try_extend.should == false
    end
  end
end
