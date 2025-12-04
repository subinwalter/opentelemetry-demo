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

        // CHAOS SCENARIO: DB Connection Storm
        if (_dbConnectionStorm)
        {
            _logger?.LogInformation("DB connection without pooling enabled");
            optionsBuilder.UseNpgsql(connectionString + ";Pooling=false").UseSnakeCaseNamingConvention();
        }
        else
        {
            _logger?.LogInformation("DB connection with pooling enabled");
            optionsBuilder.UseNpgsql(connectionString).UseSnakeCaseNamingConvention();
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

    public Consumer(ILogger<Consumer> logger, IFeatureClient featureClient)
    {
        _logger = logger;
        _featureClient = featureClient;

        var servers = Environment.GetEnvironmentVariable("KAFKA_ADDR")
            ?? throw new ArgumentNullException("KAFKA_ADDR");

        _consumer = BuildConsumer(servers);
        _consumer.Subscribe(TopicName);

        _logger.LogInformation($"Connecting to Kafka: {servers}");
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
                    using var activity = MyActivitySource.StartActivity("order-consumed",  ActivityKind.Internal);
                    var consumeResult = _consumer.Consume();
                    ProcessMessage(consumeResult.Message);
                }
                catch (ConsumeException e)
                {
                    _logger.LogError(e, "Consume error: {0}", e.Error.Reason);
                }
            }
        }
        catch (OperationCanceledException)
        {
            _logger.LogInformation("Closing consumer");

            _consumer.Close();
        }
    }

    private async void ProcessMessage(Message<string, byte[]> message)
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
            _logger.LogInformation($"Feature flag accountingDBConnectionStorm value: {dbConnectionStorm}");
            using var dbContext = new DBContext(dbConnectionStorm, _logger);

            var orderEntity = new OrderEntity
            {
                Id = order.OrderId
            };
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
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Order parsing failed:");
        }
    }

    private IConsumer<string, byte[]> BuildConsumer(string servers)
    {
        var conf = new ConsumerConfig
        {
            GroupId = $"accounting",
            BootstrapServers = servers,
            // https://github.com/confluentinc/confluent-kafka-dotnet/tree/07de95ed647af80a0db39ce6a8891a630423b952#basic-consumer-example
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = true
        };

        return new ConsumerBuilder<string, byte[]>(conf)
            .Build();
    }

    public void Dispose()
    {
        _isListening = false;
        _consumer?.Dispose();
    }
}
