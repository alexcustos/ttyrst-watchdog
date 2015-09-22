/**
 * Created by Aleksandr Borisenko
 */
#include "logrecord.h"
#include <EEPROM.h>
#include <Time.h>
#include <avr/wdt.h>

#define CMD_ACTIVATE 0
#define CMD_DEACTIVATE 1
#define CMD_SYNC 2
#define CMD_TIMER 3
#define CMD_STATUS 4
#define CMD_LOG 5
#define CMD_RESET 6

#define CMD_MIN_LEN 3
#define CMD_MAX_LEN 32

String gCmd = "";
boolean gActivated = false;
time_t gResetTime = 0;
unsigned int gResetMin = 0;
boolean gBootLogged = false;

#define PIN_LED 13
#define PIN_RESET 12

void setup() {
  wdt_enable(WDTO_8S);
  disable();
  gCmd.reserve(CMD_MAX_LEN);
  gBootLogged = false;
  gLogPos = findEmptyLogRecord();
  Serial.begin(9600);
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_RESET, OUTPUT);
}

void loop() {
  wdt_reset();

  if (Serial.available())
  {
    if (receiveCmd()) {
      execCmd(gCmd);
      gCmd = "";
    }
  }

  if (isEnabled())
    watchdog();

  if (gActivated)
    digitalWrite(PIN_LED, HIGH);
  else
    digitalWrite(PIN_LED, LOW);
}

void watchdog () {
  int delta = gResetTime - now();

  if (delta < 0) {
    disable();
    LogRecord record = {now(), LOG_RESET};
    writeLogRecord(record);

    digitalWrite(PIN_RESET, HIGH);
    delay(1000);
    digitalWrite(PIN_RESET, LOW);
  } else if (gResetMin > delta || gResetMin <= 0) {
    gResetMin = delta;
  }
}

void execCmd(String cmd) {
  String cmdName = getCmdPart(cmd, ' ', 0);
  String cmdArg0 = getCmdPart(cmd, ' ', 1);
  String cmdArg1 = getCmdPart(cmd, ' ', 2);
  
  switch (getCmdID(cmdName)) {
    case CMD_ACTIVATE:
      gActivated = true;
      Serial.println("OK");
      break;
    case CMD_DEACTIVATE:
      disable();
      Serial.println("OK");
      break;
    case CMD_SYNC:
      if (cmdArg0.length() == 10) {
        syncTime(cmdArg0);
        Serial.println(now());
      } else {
        Serial.println("NOOP");
      }
      break;
    case CMD_TIMER:
      {
        unsigned int timer = cmdArg1.toInt();
        if (cmdArg0.length() == 10 && timer > 0) {
          syncTime(cmdArg0);
          gResetTime = now() + timer;
          if (gActivated)
            Serial.println("YES");
          else
            Serial.println("NO");
        } else {
          Serial.println("NOOP");
        }
      }
      break;
    case CMD_STATUS:
      Serial.print(getClock(now()));
      Serial.print(";");
      if (isEnabled())
        Serial.print("ON");
      else
        Serial.print("OFF");
      Serial.print(";");
      if (gActivated)
        Serial.print("YES");
      else
        Serial.print("NO");
      Serial.print(";");
      if (gResetTime > 0)
        Serial.print(gResetTime - now());
      else
        Serial.print("0");
      Serial.print(";");
      Serial.print(gResetMin);
      Serial.println();
      break;
    case CMD_LOG:
      {
        int lines = cmdArg0.toInt();
        if (lines <= 0)
          lines = 32767;
        printLog(lines);
      }
      break;
    case CMD_RESET:
      clearLog();
      if (gLogPos == 0)
        Serial.println("OK");
      wdt_enable(WDTO_30MS);
      while(1) {};
      break;
    default:
      Serial.println("NOOP");
      break;
  } // switch
  
}

void syncTime(String ts) {
  time_t pctime = ts.toInt();
  
  if (pctime > 0)
    setTime(pctime);
    
  if (!gBootLogged) {
    gBootLogged = true;
    LogRecord record = {now(), LOG_BOOT};
    writeLogRecord(record);
  }
}

boolean receiveCmd() {
  short len = gCmd.length();
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (len < CMD_MAX_LEN) {
      gCmd += c;
      len++;
    }
    if (c == '\n' || c == '\r') {
      gCmd.trim();
      if (gCmd.length() >= CMD_MIN_LEN)
        return true;
      else
        gCmd = "";
    }
  } // while
  return false;
}

String getCmdPart(String cmd, char separator, int index) {
    int count = 0;
    String cmdPart = "";
    for (int i = 0; i < cmd.length(); i++) {
      if (cmd[i] == separator)
        count++;
      else if (count == index)
        cmdPart += cmd[i];
      else if(count > index)
        return cmdPart;
    }
    return cmdPart;
}

short getCmdID(String cmd) {
  if (cmd.equalsIgnoreCase("activate"))
    return CMD_ACTIVATE;
  else if (cmd.equalsIgnoreCase("deactivate"))
    return CMD_DEACTIVATE;
  else if (cmd.equalsIgnoreCase("sync"))
    return CMD_SYNC;
  else if (cmd.equalsIgnoreCase("timer"))
    return CMD_TIMER;
  else if (cmd.equalsIgnoreCase("status"))
    return CMD_STATUS;
  else if (cmd.equalsIgnoreCase("log"))
    return CMD_LOG;
  else if (cmd.equalsIgnoreCase("reset"))
    return CMD_RESET;
}

String getClock(time_t t) {
  String clock = digitsFormat(day(t), 2) + "-" + digitsFormat(month(t), 2) + "-" + year(t);
  clock += " " + digitsFormat(hour(t), 2) + ":" + digitsFormat(minute(t), 2) + ":" + digitsFormat(second(t), 2);
  return clock;
}

String digitsFormat(int digits, short num) {
  short len = String(digits).length();
  String prefix = "";
  for(short i = 0; i < num-len; i++)
    prefix += '0';
  return prefix + String(digits);
}

boolean isEnabled() {
  return (gActivated && gResetTime > 0);
}

boolean disable() {
  gResetTime = 0;
  gActivated = false;
}

void writeLogRecord(const LogRecord &record)
{
  const byte *p = (const byte*)(const void*)&record;
  unsigned int i;
  unsigned int pos = gLogPos;

  if (pos >= gEepromSize)
    pos = 0;  

  for (i = 0; i < gLogRecordLen; i++)
    EEPROM.write(pos++, *p++);

  if (pos >= gEepromSize) {
    gLogPos = 0;
    pos = 0;
  } else {
    gLogPos = pos;
  }

  p = (const byte*)(const void*)&gEmptyRecord;
  for (i = 0; i < gLogRecordLen; i++)
    EEPROM.write(pos++, *p++);
}

unsigned int readLogRecord(unsigned int pos, LogRecord &record)
{
  if (pos >= gEepromSize)
    pos = 0;  
  byte *p = (byte*)(void*)&record;
  for (unsigned int i = 0; i < gLogRecordLen; i++)
    *p++ = EEPROM.read(pos++);
  // next
  if (pos >= gEepromSize)
    pos = 0;  
  return pos;
}

unsigned int findEmptyLogRecord()
{
  LogRecord record;
  for (unsigned int pos = 0; pos < gEepromSize; pos+=gLogRecordLen) {
    readLogRecord(pos, record);
    if (record.logTime == 0 && record.logEvent == LOG_EMPTY)
      return pos;
  }
  return 0;  // it is better than just stop with log corruption error
}

void clearLog()
{
  gLogPos = 0;
  for (unsigned int i = 0; i < gEepromSize; i+=gLogRecordLen)
    writeLogRecord(gEmptyRecord);
}

void printLog(int lines)
{
  LogRecord record;
  unsigned int pos, next;
  const unsigned int maxRecords = gEepromSize / gLogRecordLen;
  int count, numRecords;

  // better place to inform about log corruption than findEmptyLogRecord
  for (pos = 0; pos < gEepromSize; pos+=gLogRecordLen) {
    next = readLogRecord(pos, record);
    if (record.logTime == 0 && record.logEvent == LOG_EMPTY)
      break;
  }
  if (pos >= gEepromSize) {
      Serial.println("The first log record was not found. Please erase EEPROM to fix it.");
      return;
  }
  
  wdt_reset();
  // search for the first record
  count = 0;
  do {
    count++;
    if (count >= maxRecords)
      break; // log empty
    pos = next;
    next = readLogRecord(pos, record);
  } while(record.logTime == 0 && record.logEvent == LOG_EMPTY);
  numRecords = maxRecords - count;
  
  count = 0;
  while (record.logTime > 0 && record.logEvent != LOG_EMPTY) {
    wdt_reset();
    count++;
    if (count >= maxRecords) {
      Serial.println("Dead loop detected. Please erase EEPROM to fix it.");
      break;    
    }
    if (numRecords - lines < count) {
      Serial.print(digitsFormat(count, 3));
      Serial.print(":");
      Serial.print(digitsFormat(pos, 4));
      Serial.print("; ");
      Serial.print(getClock(record.logTime));
      Serial.print("; ");
      switch (record.logEvent) {
        case LOG_BOOT:
          Serial.print("BOOT");
          break;
        case LOG_RESET:
          Serial.print("RESET");
          break;
        default:
          Serial.print("NOOP");
          break;
      } // switch
      Serial.println();
    }
    pos = next;
    next = readLogRecord(pos, record);
  } // while
  Serial.println("DONE");
}

