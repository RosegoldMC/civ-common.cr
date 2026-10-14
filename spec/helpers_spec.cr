require "spec"
require "../src/rosegold-civ-common"

class FakeHand
  property name = "emerald"

  def empty?
    name.empty?
  end
end

class FakeInventory
  getter main_hand = FakeHand.new
  property amount = 10
  property? available = true

  def pick(name)
    available?
  end

  def count(name)
    amount
  end
end

class FakeBot
  include Rosegold::CivCommon::Helpers
  property y = 0.0
  property? connected = true
  property? sneaking = false
  property? jumping = false
  property pitch = 15.0
  property hotbar_selection = 1_u8
  property experience_level = 0
  getter inventory = FakeInventory.new
  getter uses = 0
  getter releases = 0
  getter ticks = 0
  property on_tick : Proc(Nil)?

  def wait_tick
    @ticks += 1
    on_tick.try(&.call)
  end

  def start_jump
    @jumping = true
  end

  def stop_jump
    @jumping = false
  end

  def sneak
    @sneaking = true
  end

  def unsneak
    @sneaking = false
  end

  def use_hand
    @uses += 1
  end

  def stop_using_hand
    @releases += 1
  end
end

describe Rosegold::CivCommon::Helpers do
  it "arrives going up and releases the queued jump" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.y = 10.0; nil }
    bot.elevator(10)
    bot.jumping?.should be_false
  end

  it "arrives going down and releases sneak" do
    bot = FakeBot.new
    bot.y = 10.0
    bot.on_tick = -> { bot.y = 0.0; nil }
    bot.elevator(0)
    bot.sneaking?.should be_false
  end

  it "returns immediately at the destination" do
    bot = FakeBot.new
    bot.elevator(0)
    bot.ticks.should eq(0)
  end

  it "reports stalls and releases jump" do
    bot = FakeBot.new
    error = expect_raises(Rosegold::CivCommon::MovementError) { bot.elevator(10) }
    error.reason.stalled?.should be_true
    bot.jumping?.should be_false
  end

  it "detects falling below the lower endpoint" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.y = -2.0; nil }
    error = expect_raises(Rosegold::CivCommon::MovementError) { bot.elevator(10) }
    error.reason.falling?.should be_true
  end

  it "bounds tick use and reports timeout" do
    bot = FakeBot.new
    error = expect_raises(Rosegold::CivCommon::MovementError) { bot.elevator(10, timeout_ticks: 3) }
    error.reason.timeout?.should be_true
    bot.ticks.should eq(3)
  end

  it "releases sneak after an unexpected descent failure" do
    bot = FakeBot.new
    bot.y = 10.0
    bot.on_tick = -> { raise "transport failed" }
    expect_raises(Exception, "transport failed") { bot.elevator(0) }
    bot.sneaking?.should be_false
  end

  it "reports disconnects" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.connected = false; nil }
    error = expect_raises(Rosegold::CivCommon::MovementError) { bot.elevator(10) }
    error.reason.disconnected?.should be_true
  end

  it "taps every two ticks and completes from observed XP" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.experience_level = 3 if bot.uses == 2; nil }
    result = bot.raise_level_with("emerald", 3)
    result.completed?.should be_true
    result.final_level.should eq(3)
    bot.uses.should eq(2)
    bot.ticks.should eq(5)
    bot.pitch.should eq(15.0)
    bot.releases.should eq(1)
  end

  it "does nothing when XP is already sufficient" do
    bot = FakeBot.new
    bot.raise_level_with("emerald", 0).completed?.should be_true
    bot.ticks.should eq(0)
    bot.releases.should eq(0)
  end

  it "reports missing carried items" do
    bot = FakeBot.new
    bot.inventory.available = false
    bot.raise_level_with("emerald", 3).reason.depleted?.should be_true
  end

  it "reports item depletion" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.inventory.amount = 0; nil }
    bot.raise_level_with("emerald", 3).reason.depleted?.should be_true
    bot.pitch.should eq(15.0)
  end

  it "preserves an externally changed slot and look" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.hotbar_selection = 2_u8; bot.pitch = 30.0; nil }
    bot.raise_level_with("emerald", 3).reason.hand_changed?.should be_true
    bot.hotbar_selection.should eq(2)
    bot.pitch.should eq(30.0)
  end

  it "stops if the main hand changes" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.inventory.main_hand.name = "stone"; nil }
    bot.raise_level_with("emerald", 3).reason.hand_changed?.should be_true
    bot.uses.should eq(0)
  end

  it "reports XP timeout and releases use" do
    bot = FakeBot.new
    bot.raise_level_with("emerald", 3, timeout_ticks: 4).reason.timeout?.should be_true
    bot.releases.should eq(1)
    bot.pitch.should eq(15.0)
  end

  it "cancels XP before any input" do
    bot = FakeBot.new
    token = Rosegold::CivCommon::Cancellation.new
    token.cancel
    bot.raise_level_with("emerald", 3, cancellation: token).reason.cancelled?.should be_true
    bot.uses.should eq(0)
  end

  it "releases jump after an unexpected failure" do
    bot = FakeBot.new
    bot.on_tick = -> { raise "transport failed" }
    expect_raises(Exception, "transport failed") { bot.elevator(10) }
    bot.jumping?.should be_false
  end
  it "keeps pre-existing sneak held" do
    bot = FakeBot.new
    bot.y = 10.0
    bot.sneaking = true
    bot.on_tick = -> { bot.y = 0.0; nil }
    bot.elevator(0)
    bot.sneaking?.should be_true
  end

  it "cleans up XP use after an unexpected failure" do
    bot = FakeBot.new
    bot.on_tick = -> { raise "transport failed" if bot.uses > 0; nil }
    expect_raises(Exception, "transport failed") { bot.raise_level_with("emerald", 3) }
    bot.releases.should eq(1)
    bot.pitch.should eq(15.0)
  end

  it "reports a disconnect during XP use" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.connected = false; nil }
    bot.raise_level_with("emerald", 3).reason.disconnected?.should be_true
  end

  it "cancels during XP use and releases use" do
    bot = FakeBot.new
    token = Rosegold::CivCommon::Cancellation.new
    bot.on_tick = -> { token.cancel if bot.uses > 0; nil }
    bot.raise_level_with("emerald", 3, cancellation: token).reason.cancelled?.should be_true
    bot.releases.should eq(1)
    bot.pitch.should eq(15.0)
  end

  it "bounds absent progress by monotonic time" do
    bot = FakeBot.new
    bot.on_tick = -> { sleep 0.12.seconds }
    started = Time.monotonic
    error = expect_raises(Rosegold::CivCommon::MovementError) { bot.elevator(10, timeout_ticks: 2) }
    error.reason.timeout?.should be_true
    bot.ticks.should eq(1)
    (Time.monotonic - started).should be < 1.second
  end
  it "accepts XP observed on the final allowed tick" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.experience_level = 3 if bot.ticks == 4; nil }
    bot.raise_level_with("emerald", 3, timeout_ticks: 4).completed?.should be_true
  end

  it "accepts XP observed on an odd final allowed tick" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.experience_level = 3 if bot.ticks == 3; nil }
    result = bot.raise_level_with("emerald", 3, timeout_ticks: 3)
    result.completed?.should be_true
    result.final_level.should eq(3)
    bot.ticks.should eq(3)
    bot.releases.should eq(1)
  end

  it "accepts arrival on the final allowed tick" do
    bot = FakeBot.new
    bot.on_tick = -> { bot.y = 10.0 if bot.ticks == 3; nil }
    bot.elevator(10, timeout_ticks: 3)
    bot.jumping?.should be_false
  end
end
