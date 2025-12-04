// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

using Microsoft.Extensions.Logging;
using Oteldemo;

namespace Accounting
{
    internal static partial class Log
    {
        [LoggerMessage(
            Level = LogLevel.Information,
            Message = "Order details: {@OrderResult}.")]
        public static partial void OrderReceivedMessage(ILogger logger, OrderResult orderResult);

        [LoggerMessage(
            Level = LogLevel.Information,
            Message = "Creating new DB connection without pooling (chaos mode)")]
        public static partial void DbConnectionChaosMode(ILogger logger);

        [LoggerMessage(
            Level = LogLevel.Information,
            Message = "Creating new DB connection with pooling")]
        public static partial void DbConnectionNormalMode(ILogger logger);
    }
}
