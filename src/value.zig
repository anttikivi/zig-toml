pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,

    /// Timezone offset in minutes from UTC. If `null`, it means local datetime.
    tz: ?i16 = null,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.year == other.year and
            self.month == other.month and
            self.day == other.day and
            self.hour == other.hour and
            self.minute == other.minute and
            self.second == other.second and
            self.nano == other.nano and
            self.tz == other.tz;
    }

    pub fn isValid(self: @This()) bool {
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };
        if (self.day == 0 or self.day > days_in_month[self.month - 1]) {
            return false;
        }

        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        if ((self.month == 6 and self.day == 30) or (self.month == 12 and self.day == 31)) {
            if (self.second > 60) {
                return false;
            }
        } else if (self.second > 59) {
            return false;
        }

        return if (self.tz) |tz| isValidTimezone(tz) else true;
    }
};

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.year == other.year and
            self.month == other.month and
            self.day == other.day;
    }

    pub fn isValid(self: @This()) bool {
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };

        return self.day > 0 and self.day <= days_in_month[self.month - 1];
    }
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.hour == other.hour and
            self.minute == other.minute and
            self.second == other.second and
            self.nano == other.nano;
    }

    pub fn isValid(self: @This()) bool {
        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        return self.second <= 59;
    }
};

fn isValidTimezone(tz: i16) bool {
    const t: u16 = @abs(tz);
    const h = t / 60;
    const m = t % 60;

    if (h > 23) {
        return false;
    }

    return m < 60;
}
