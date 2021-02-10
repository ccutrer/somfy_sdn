The SDN protocol has two major iterations - ILTv2, and ILTv3. A few of the messages are shared, and ILTv3 retains
backwards compatibility with ILTv2. In general every message has three forms - a GET, a SET, and a POST. GET asks the
motor to return (or POST) the current values, and SET asks the motor to update that value. Of course, there are
exceptions - for example, ILTv3 introduces several control messages that command it to do something, but not directly
set a value. And some things are read-only (like node address).

Every node has a three byte address assigned at the factory. In addition, you can assign up to 16 group addresses to each
motor. And finally, most GET requests will respond to a broadcast address. This is useful for discovery - i.e.
GET_NODE_ADDR sent to the broadcast address will be "discovery" for an entire network. Or a reliable way to get the
address of a motor you're directly attached to. You could also send it to the group address to get the list of motors
assigned to a particular group. Addresses are formatted as three sets of two hex digits, separated by periods or colons.
One oddity to note is that when doing group mode addressing, you put the destination (the group address) in the source,
and the destination as all 0s. Motors can tell this is happening, because group addresses must be in the range
01:01:00-01:01:FF.

The basic message structure is as follows:

|MSG(1)|LENGTH(1)|NODE_TYPE(1)|SOURCE_ADDRESS(3)|DESTINATION_ADDRESS(3)|OPTIONAL_PARAMETERS|CHECKSUM(2)|

 * The message type is a code, from one of the below tables.
 * The length is the total message length, including the message type, length byte, and checksum.
   Additionally, if the high bit of the length is set, it is a flag to say you're requesting an ACK or
   NACK for this request. For GET messages, this is ignored since a POST response will be sent anyway, but is
   useful to ensure a SET or control message was received. For ILTv2, the motor seems to _always_ return a NACK,
   even when it was succesful. This is at least useful for knowing the message got through.
 * The Node Type is the type of motor sending the message. It can take one of the following values (or more?):
   * 0x00 - No type. Generally this is used for sending messages _to_ motors, from a controlling program, like a ZDMI, a UAI+,
     or this gem.
   * 0x01 - ST50, speaking ILTv2
   * 0x02 - ST30, speaking ILTv3 (supposedly having address range 06:00:00-07:FF:FF, but this doesn't seem important)
   * 0x06 - Glydea
   * 0x07 - ST50 AC, speaking ILTv3
   * 0x08 - ST50 DC, speaking ILTv3
   * 0x70 - LT50, speaking ILTv3
 * Additional parameters are dependent on the message type.
 * The checksum is two bytes, a simple sum of all preceding bytes, stored big endian.

 When written/read on the wire, every byte in the message is subtracted from 0xFF. The serial parameters are 4800,8O1 i.e.
 4800 baud, 8 data bits, odd parity, 1 stop bit.


Italicized messages in the following tables are not implemented by this library.

Somfy refers to the first group of messages as Motor Control profile:


|  |        0x00         |  |           0x10            |  |           0x20            |  |            0x30            |
|--| ------------------- |--| ------------------------- |--| ------------------------- |--| -------------------------- |
|00|                     |10| _SET_APP_MODE_            |20|                           |30|                            |
|01| CTRL_MOVE           |11| SET_MOTOR_LIMITS          |21| GET_MOTOR_LIMITS          |31| POST_MOTOR_LIMITS          |
|02| CTRL_STOP           |12| SET_MOTOR_DIRECTION       |22| GET_MOTOR_DIRECTION       |32| POST_MOTOR_DIRECTION       |
|03| CTRL_MOVETO         |13| SET_MOTOR_ROLLING_SPEED   |23| GET_MOTOR_ROLLING_SPEED   |33| POST_MOTOR_ROLLING_SPEED   |
|04| CTRL_MOVEOF         |14| _SET_MOTOR_TILTING_SPEED_ |24| _GET_MOTOR_TILTING_SPEED_ |34| _POST_MOTOR_TILTING_SPEED_ |
|05| CTRL_WINK           |15| SET_MOTOR_IP              |25| GET_MOTOR_IP              |35| POST_MOTOR_IP              |
|06| CTRL_LOCK           |16| SET_NETWORK_LOCK          |26| GET_NETWORK_LOCK          |36| POST_NETWORK_LOCK          |
|07|                     |17| _SET_DCT_LOCK_            |27| _GET_DCT_LOCK_            |37| _POST_DCT_LOCK_            |
|08|                     |18|                           |28|                           |38|                            |
|09|                     |19|                           |29|                           |39|                            |
|0a|                     |1a|                           |2a|                           |3a|                            |
|0b|                     |1b|                           |2b|                           |3b|                            |
|0c| GET_MOTOR_POSITION  |1c|                           |2c|                           |3c|                            |
|0d| POST_MOTOR_POSITION |1d|                           |2d|                           |3d|                            |
|0e| GET_MOTOR_STATUS    |1e|                           |2e|                           |3e|                            |
|0f| POST_MOTOR_STATUS   |1f| SET_FACTORY_DEFAULT       |2f| GET_FACTORY_DEFAULT       |3f| POST_FACTORY_DEFAULT       |


The second and third group of messages (intermingled) are Mandatary Messages, and ILTv2 Compatibility Messages. Note
that ILTv2 implements _some_ of the Mandatory Messages.

|  |           0x40           |  |          0x50           |  |           0x60            |  |          0x70           |
|--| ------------------------ |--| ----------------------- |--| ------------------------- |--| ----------------------- |
|40| GET_NODE_ADDR            |50|                         |60| POST_NODE_ADDR            |70| GET_NODE_STACK_VERSION  |
|41| GET_GROUP_ADDR           |51| SET_GROUP_ADDR          |61| POST_GROUP_ADDR           |71| POST_NODE_STACK_VERSION |
|42| ILT2_GET_MOTOR_SETTINGS  |52| ILT2_SET_MOTOR_SETTINGS |62| ILT2_POST_MOTOR_SETTINGS  |72|                         |
|43| ILT2_GET_MOTOR_IP        |53| ILT2_SET_MOTOR_IP       |63| ILT2_POST_MOTOR_IP        |73|                         |
|44| ILT2_GET_MOTOR_POSITION  |54| ILT2_SET_MOTOR_POSITION |64| ILT2_POST_MOTOR_POSITION  |74| GET_NODE_APP_VERSION    |
|45| GET_NODE_LABEL           |55| SET_NODE_LABEL          |65| POST_NODE_LABEL           |75| POST_NODE_APP_VERSION   |
|46|                          |56|                         |66|                           |76|                         |
|47|                          |57|                         |67|                           |77|                         |
|48|                          |58|                         |68|                           |78|                         |
|49| ILT2_GET_IR_CONFIG       |59| ILT2_SET_IR_CONFIG      |69| ILT2_POST_IR_CONFIG       |79|                         |
|4a|                          |5a|                         |6a|                           |7a|                         |
|4b| ILT2_GET_LOCK_STATUS     |5b| ILT2_SET_LOCK_STATUS    |6b| ILT2_POST_LOCK_STATUS     |7b|                         |
|4c| GET_NODE_SERIAL_NUMBER   |5c| _ILT2_SET_MOTOR_LIMITS_ |6c| POST_NODE_SERIAL_NUMBER_  |7c|                         |
|4d| _GET_NETWORK_ERROR_STAT_ |5d|                         |6d| _POST_NETWORK_ERROR_STAT_ |7d|                         |
|4e| _GET_NETWORK_STAT_       |5e| _SET_NETWORK_STAT_      |6e| _POST_NETWORK_STAT_       |7e|                         |
|4f|                          |5f|                         |6f| NACK                      |7f| ACK                     |

There's also a fourth group of Factory Mode Messages from 0x80-0xff, but these are not included since they're not
generally useful.