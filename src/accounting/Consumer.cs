// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

using Confluent.Kafka;
using Microsoft.Extensions.Logging;
using Oteldemo;
using Microsoft.EntityFrameworkCore;
using System.Diagnostics;
using OpenFeature;

namespace Accounting;

internal class DBContext : DbContext
{
    private readonly bool _dbConnectionStorm;
    private readonly ILogger? _logger;

    public DbSet<OrderEntity> Orders { get; set; }
    public DbSet<OrderItemEntity> CartItems { get; set; }
    public DbSet<ShippingEntity> Shipping { get; set; }

    public DBContext(bool dbConnectionStorm, ILogger? logger = null)
    {
        _dbConnectionStorm = dbConnectionStorm;
        _logger = logger;
    }

    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
    {
        var connectionString = Environment.GetEnvironmentVariable("DB_CONNECTION_STRING");

        if (_dbConnectionStorm)
        {
            _logger?.LogInformation("DB connection without pooling enabled");
            optionsBuilder.UseNpgsql(connectionString + ";Pooling=false;Timeout=5")
                .UseSnakeCaseNamingConvention();
        }
        else
        {
            _logger?.LogInformation("DB connection with pooling enabled");
            optionsBuilder.UseNpgsql(connectionString)
                .UseSnakeCaseNamingConvention();
        }
    }
}

internal class Consumer : IDisposable
{
    private const string TopicName = "orders";

    private ILogger _logger;
    private IConsumer<string, byte[]> _consumer;
    private bool _isListening;
    private bool _hasDbConnection;
    private IFeatureClient _featureClient;
    private static readonly ActivitySource MyActivitySource = new("Accounting.Consumer");

    // Track leaked connection count
    private static int _totalLeakedConnections = 0;

    public Consumer(ILogger<Consumer> logger, IFeatureClient featureClient)
    {
        _logger = logger;
        _featureClient = featureClient;

        var servers = Environment.GetEnvironmentVariable("KAFKA_ADDR")
            ?? throw new ArgumentNullException("KAFKA_ADDR");

        _consumer = BuildConsumer(servers);
        _consumer.Subscribe(TopicName);

        _logger.LogInformation("Connecting to Kafka: {Servers}", servers);
        _hasDbConnection = Environment.GetEnvironmentVariable("DB_CONNECTION_STRING") != null;
    }

    public void StartListening()
    {
        _isListening = true;

        try
        {
            while (_isListening)
            {
                try
                {
                    using var activity = MyActivitySource.StartActivity("order-consumed", ActivityKind.Internal);
                    var consumeResult = _consumer.Consume();
                    _ = Task.Run(() => ProcessMessage(consumeResult.Message));
                }
                catch (ConsumeException e)
                {
                    _logger.LogError(e, "Consume error: {Reason}", e.Error.Reason);
                }
            }
        }
        catch (OperationCanceledException)
        {
            _logger.LogInformation("Closing consumer");
            _consumer.Close();
        }
    }

    private async Task ProcessMessage(Message<string, byte[]> message)
    {
        try
        {
            var order = OrderResult.Parser.ParseFrom(message.Value);
            Log.OrderReceivedMessage(_logger, order);

            if (!_hasDbConnection)
            {
                return;
            }

            var dbConnectionStorm = await _featureClient.GetBooleanValueAsync("accountingDBConnectionStorm", false);
            _logger.LogInformation("Feature flag accountingDBConnectionStorm value: {Value}", dbConnectionStorm);

            using var dbContext = new DBContext(dbConnectionStorm, _logger);
            var orderEntity = new OrderEntity { Id = order.OrderId };
            dbContext.Add(orderEntity);

            foreach (var item in order.Items)
            {
                var orderItem = new OrderItemEntity
                {
                    ItemCostCurrencyCode = item.Cost.CurrencyCode,
                    ItemCostUnits = item.Cost.Units,
                    ItemCostNanos = item.Cost.Nanos,
                    ProductId = item.Item.ProductId,
                    Quantity = item.Item.Quantity,
                    OrderId = order.OrderId
                };
                dbContext.Add(orderItem);
            }

            var shipping = new ShippingEntity
            {
                ShippingTrackingId = order.ShippingTrackingId,
                ShippingCostCurrencyCode = order.ShippingCost.CurrencyCode,
                ShippingCostUnits = order.ShippingCost.Units,
                ShippingCostNanos = order.ShippingCost.Nanos,
                StreetAddress = order.ShippingAddress.StreetAddress,
                City = order.ShippingAddress.City,
                State = order.ShippingAddress.State,
                Country = order.ShippingAddress.Country,
                ZipCode = order.ShippingAddress.ZipCode,
                OrderId = order.OrderId
            };
            dbContext.Add(shipping);
            dbContext.SaveChanges();

            if (dbConnectionStorm)
            {
                CreateConnectionStorm(order.OrderId);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Order processing failed");
        }
    }

    private void CreateConnectionStorm(string orderId)
    {
        _logger.LogWarning("Starting DB connection storm for order {OrderId}", orderId);

        // Leak connections for a fixed duration
        for (int i = 0; i < 5; i++)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    var leakedContext = new DBContext(true, _logger);
                    await leakedContext.Database.OpenConnectionAsync();

                    var count = Interlocked.Increment(ref _totalLeakedConnections);
                    _logger.LogWarning("Leaked connection {Count} for order {OrderId}", count, orderId);

                    await Task.Delay(300000); // Hold for 5 minutes

                    leakedContext.Dispose();
                    Interlocked.Decrement(ref _totalLeakedConnections);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to leak connection");
                }
            });
        }

        // Long-lived idle connections
        for (int i = 0; i < 5; i++)
        {
            var connectionIndex = i;
            _ = Task.Run(async () =>
            {
                try
                {
                    using var idleContext = new DBContext(true, _logger);
                    await idleContext.Database.OpenConnectionAsync();

                    var holdTime = Random.Shared.Next(30000, 60000);
                    _logger.LogWarning("Holding idle connection {Index} for {Duration}ms, order {OrderId}",
                        connectionIndex, holdTime, orderId);

                    await Task.Delay(holdTime);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Idle connection failed");
                }
            });
        }

        // Rapid connection churn
        _ = Task.Run(async () =>
        {
            _logger.LogWarning("Starting rapid connection churn for order {OrderId}", orderId);
            for (int i = 0; i < 20; i++)
            {
                try
                {
                    using var churnContext = new DBContext(true, _logger);
                    await churnContext.Database.OpenConnectionAsync();
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Connection churn failed at iteration {Iteration}", i);
                }
            }
            _logger.LogWarning("Completed connection churn for order {OrderId}", orderId);
        });

        // Concurrent connection burst
        for (int i = 0; i < 10; i++)
        {
            var index = i;
            _ = Task.Run(async () =>
            {
                try
                {
                    using var burstContext = new DBContext(true, _logger);
                    await burstContext.Database.OpenConnectionAsync();
                    await Task.Delay(Random.Shared.Next(5000, 15000));
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Burst connection {Index} failed", index);
                }
            });
        }

        _logger.LogWarning("Connection storm initiated for order {OrderId}, total leaked: {Count}",
            orderId, _totalLeakedConnections);
    }

    private IConsumer<string, byte[]> BuildConsumer(string servers)
    {
        var conf = new ConsumerConfig
        {
            GroupId = "accounting",
            BootstrapServers = servers,
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = true
        };

        return new ConsumerBuilder<string, byte[]>(conf).Build();
    }

    public void Dispose()
    {
        _isListening = false;
        _consumer?.Dispose();
    }
}
