/**
 * Created by Aleksandr Borisenko
 */
#include <Time.h>

#define LOG_EMPTY 0
#define LOG_BOOT 1
#define LOG_RESET 2

struct LogRecord {
  time_t logTime;
  unsigned char logEvent;
};

const unsigned int gLogRecordLen = sizeof(LogRecord);
const unsigned int gEepromSize = 1024 / gLogRecordLen * gLogRecordLen;

unsigned int gLogPos = 0;

LogRecord gEmptyRecord = {0, 0};

