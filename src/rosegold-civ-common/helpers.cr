module Rosegold::CivCommon
  # Cooperative cancellation for XP consumption.
  class Cancellation
    getter? cancelled = false

    def cancel
      @cancelled = true
    end
  end

  enum StopReason
    Completed
    Depleted
    HandChanged
    Disconnected
    Cancelled
    Timeout
    Stalled
    Falling
  end

  record ExperienceResult, reason : StopReason, final_level : Int32 do
    def completed? : Bool
      reason.completed?
    end
  end

  class MovementError < Exception
    getter reason : StopReason

    def initialize(@reason)
      super("Elevator stopped: #{reason}")
    end
  end

  private class Interrupted < Exception
    getter reason : StopReason

    def initialize(@reason)
      super(reason.to_s)
    end
  end

  private class Budget
    @remaining : Int32
    @deadline : Time::Span

    def initialize(ticks : Int32, @cancellation : Cancellation?)
      raise ArgumentError.new("timeout_ticks must be positive") unless ticks > 0
      @remaining = ticks
      @deadline = Time.monotonic + ticks.to_f.seconds / 20
    end

    def check_state(connected : Bool)
      raise Interrupted.new(:disconnected) unless connected
      raise Interrupted.new(:cancelled) if @cancellation.try(&.cancelled?)
    end

    def check(connected : Bool)
      check_state(connected)
      raise Interrupted.new(:timeout) if @remaining <= 0 || Time.monotonic >= @deadline
    end

    def advance
      @remaining -= 1
    end
  end

  # Include only in bots whose server policy permits each underlying observation.
  # Callers must give helpers exclusive control of movement, look, and item use.
  module Helpers
    # Rides a known jump/sneak elevator to *target_y*. Raises MovementError on
    # failure. Does not discover elevators or inspect blocks.
    def elevator(target_y : Number, timeout_ticks : Int32 = 1200) : Nil
      raise ArgumentError.new("target_y must be finite") unless target_y.to_f.finite?
      budget = Budget.new(timeout_ticks, nil)
      jump_owned = false
      sneak_owned = false
      last_y = y
      fall_floor = {y.to_f, target_y.to_f}.min - 1
      stuck_count = 0
      loop do
        budget.check_state(connected?)
        return if (y - target_y).abs < 0.01
        budget.check(connected?)
        raise MovementError.new(:falling) if y < fall_floor
        stuck_count = (y - last_y).abs < 0.1 ? stuck_count + 1 : 0
        raise MovementError.new(:stalled) if stuck_count > 10
        last_y = y
        if y < target_y
          jump_owned = true
          start_jump
        else
          unless sneaking?
            sneak_owned = true
            sneak
          end
          civ_elevator_wait(5, budget, target_y)
          if sneak_owned
            unsneak
            sneak_owned = false
          end
        end
        civ_elevator_wait(20, budget, target_y)
      end
    rescue ex : Interrupted
      raise MovementError.new(ex.reason)
    ensure
      stop_jump if jump_owned
      unsneak if sneak_owned
    end

    # Taps a carried XP item every two ticks until the observed target level.
    # Restores pitch and selected slot if the helper still owns those settings.
    def raise_level_with(item_name : String, target_level : Int32, timeout_ticks : Int32 = 1200, cancellation : Cancellation? = nil) : ExperienceResult
      raise ArgumentError.new("target_level must be nonnegative") if target_level < 0
      budget = Budget.new(timeout_ticks, cancellation)
      previous_pitch = pitch
      previous_slot = hotbar_selection
      selected_slot = previous_slot
      selected = false
      aimed = false
      used = false
      budget.check(connected?)
      return ExperienceResult.new(:completed, experience_level) if experience_level >= target_level
      return ExperienceResult.new(:depleted, experience_level) unless inventory.pick(item_name)
      selected = true
      selected_slot = hotbar_selection
      budget.check(connected?)
      aimed = true
      self.pitch = -90.0
      civ_xp_wait(2, budget, target_level)
      loop do
        budget.check_state(connected?)
        return ExperienceResult.new(:completed, experience_level) if experience_level >= target_level
        budget.check(connected?)
        return ExperienceResult.new(:hand_changed, experience_level) if hotbar_selection != selected_slot
        return ExperienceResult.new(:depleted, experience_level) if inventory.count(item_name) == 0
        return ExperienceResult.new(:hand_changed, experience_level) if inventory.main_hand.name != item_name
        used = true
        use_hand
        civ_xp_wait(2, budget, target_level)
      end
    rescue ex : Interrupted
      ExperienceResult.new(ex.reason, experience_level)
    ensure
      stop_using_hand if used
      if connected?
        self.pitch = previous_pitch if aimed && previous_pitch && pitch == -90.0
        if selected && previous_slot && hotbar_selection == selected_slot && (inventory.main_hand.name == item_name || inventory.main_hand.empty?)
          self.hotbar_selection = previous_slot
        end
      end
    end

    private def civ_elevator_wait(ticks : Int32, budget : Budget, target_y : Number)
      ticks.times do
        budget.check_state(connected?)
        return if (y - target_y).abs < 0.01
        budget.check(connected?)
        wait_tick
        budget.advance
      end
    end

    private def civ_xp_wait(ticks : Int32, budget : Budget, target_level : Int32)
      ticks.times do
        budget.check_state(connected?)
        return if experience_level >= target_level
        budget.check(connected?)
        wait_tick
        budget.advance
      end
    end
  end
end
